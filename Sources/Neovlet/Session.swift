import Darwin
import Foundation

private struct SessionFailure: Error, LocalizedError {
  enum Kind { case input, unavailable, uncertain, focus }
  let kind: Kind
  let message: String
  var errorDescription: String? { message }
}

/// Owns open requests, settings waits, recovery, reports and termination decisions.
@MainActor final class Session {
  enum Request: Equatable {
    case activate
    case files([URL])
    var files: [URL] { if case .files(let files) = self { files } else { [] } }
  }
  enum SettingsResult { case saved, cancelled }
  enum Outcome: Equatable { case opened, focused, closed }
  struct Problem: Equatable { let detail: String }
  struct RequestReport: Equatable {
    let request: Request
    let result: RequestResult
  }
  enum RequestResult: Equatable {
    case completed(Outcome)
    case notPerformed(Problem)
    case focusFailed(confirmed: FocusFact, problem: Problem)
  }
  enum FocusFact: Equatable { case filesDelivered, sessionReady }
  struct UnconfirmedRequest: Equatable {
    let request: Request
    let operation: UnconfirmedOperation
  }
  enum UnconfirmedOperation: Equatable { case creation, delivery, sessionVerification }
  struct StopReport: Equatable {
    let current: UnconfirmedRequest?
    let notProcessed: [Request]
    let problem: Problem
  }
  enum CancellationReason: Equatable { case settingsCancelled, managerQuit }
  enum RecoveryResult: Equatable {
    case forgotten
    case refused(RecoveryRefusal)
    case failed(Problem)
  }
  enum RecoveryRefusal: Equatable { case busy, editorStillRunning, endpointStillResponding }
  enum Report: Equatable {
    case request(RequestReport)
    case stopped(StopReport)
    case cancelled([Request], reason: CancellationReason)
    case recovery(RecoveryResult)
    case quitRefused
  }
  struct PresentationID: Hashable { fileprivate let value = UUID() }
  enum Event {
    case settingsRequired(Problem)
    case report(Report, presentation: PresentationID)
    case terminationSuggested
  }
  enum TerminationIntent { case automatic, userRequested }
  enum TerminationDecision: Equatable { case allow, cancel }

  typealias MonitorScheduler =
    @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
  private enum Operation { case resolving, opening, recovering, observing }
  private enum SettingsState { case closed, required, editing }
  private enum Lifecycle { case launching, running, terminating }
  private struct Pending {
    let id = UUID()
    let request: Request
  }
  private struct Notification {
    let event: Event
    var settingsRevision: Int? = nil
  }

  private enum RegistrationBaseline {
    case loaded(Registration)
    case committed(Registration)
    var record: Registration {
      switch self {
      case .loaded(let record), .committed(let record): record
      }
    }
  }
  private struct RegistrationEvidence {
    var baseline: RegistrationBaseline?
    var candidate: Registration?
    var records: [Registration] { [baseline?.record, candidate].compactMap { $0 } }
  }
  private enum RegistrationStep {
    case preparing, starting, terminalCreated, editorIdentified, associationVerified
  }
  private enum RegistrationIssue {
    case unreadable(Problem)
    case saveUnconfirmed(RegistrationStep, Problem)
    case removalUnconfirmed(Problem)
    case conflict(RegistrationConflict)
    case verification(Problem)
  }
  private enum RegistrationState {
    case unloaded, empty
    case tracked(RegistrationBaseline)
    case needsVerification(RegistrationEvidence, issue: RegistrationIssue)
  }
  private struct RegistrationKey: Equatable {
    let id: UUID
    let endpoint: URL
    let dependencies: Dependencies
    init(_ record: Registration) {
      id = record.id
      endpoint = record.endpoint
      dependencies = record.dependencies
    }
  }
  private struct RegistrationTarget { let record: Registration }
  private enum RegistrationReconciliation {
    case empty
    case verify(RegistrationTarget)
  }
  private enum RegistrationAdvance {
    case starting(ghostty: ProcessIdentity)
    case terminalCreated(OwnedTerminal)
    case editorIdentified(ProcessIdentity)
    case associationVerified(OwnedTerminal)
  }
  private enum RegistrationRemoval { case finishedSession, userConfirmed }
  private enum RegistrationRemovalResult {
    case removed
    case refused(RecoveryRefusal)
  }
  /// Must escape readiness polling before it can retry or clean up a partially saved record.
  private struct RegistrationCommitFailure: Error, LocalizedError {
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
  }

  private let store: any SessionStoring
  private let ghostty: any GhosttyAccess
  private let neovim: any NeovimAccess
  private let process: (Int32) throws -> ProcessIdentity?
  private let resolveDependencies: () async throws -> Dependencies
  private let notify: (Event) -> Void
  private let scheduleMonitor: MonitorScheduler
  private let startupTimeout: TimeInterval
  private let pollInterval: TimeInterval
  private var queue: [Pending] = []
  private var operation: Operation?
  private var settingsState: SettingsState = .closed
  private var settingsRevision = 0
  private var lifecycle: Lifecycle = .launching
  private var presentations: Set<PresentationID> = []
  private var notifications: [Notification] = []
  private var notifying = false
  private var terminationNotificationQueued = false
  private var cancelMonitor: (@MainActor () -> Void)?
  private var registrationState: RegistrationState = .unloaded
  private var evidence: RegistrationEvidence {
    switch registrationState {
    case .unloaded, .empty: RegistrationEvidence()
    case .tracked(let baseline): RegistrationEvidence(baseline: baseline)
    case .needsVerification(let evidence, _): evidence
    }
  }
  private var registrationClues: [Registration] {
    var records = evidence.records
    if case .needsVerification(_, .conflict(let conflict)) = registrationState {
      records += conflict.records
    }
    return records.reduce(into: []) { unique, record in
      if !unique.contains(record) { unique.append(record) }
    }
  }
  /// Only the baseline is published. A candidate is never a runnable session.
  private var registration: Registration? { evidence.baseline?.record }
  private var requiresVerification: Bool {
    if case .needsVerification = registrationState { true } else { false }
  }
  private var canObserveExit: Bool {
    switch registrationState {
    case .tracked: true
    case .needsVerification(let evidence, .verification): evidence.candidate == nil
    default: false
    }
  }
  private var registrationIsEmpty: Bool {
    if case .empty = registrationState { true } else { false }
  }
  private var unconfirmedOperation: UnconfirmedOperation?

  init(
    store: any SessionStoring, ghostty: any GhosttyAccess, neovim: any NeovimAccess,
    resolveDependencies: @escaping () async throws -> Dependencies,
    process: @escaping (Int32) throws -> ProcessIdentity? = ProcessIdentity.read,
    startupTimeout: TimeInterval = 15, pollInterval: TimeInterval = 0.15,
    scheduleMonitor: @escaping MonitorScheduler = Session.scheduleTimer,
    notify: @escaping (Event) -> Void
  ) {
    self.store = store
    self.ghostty = ghostty
    self.neovim = neovim
    self.resolveDependencies = resolveDependencies
    self.process = process
    self.startupTimeout = startupTimeout
    self.pollInterval = pollInterval
    self.scheduleMonitor = scheduleMonitor
    self.notify = notify
  }

  /// Launch readiness enables processing and monitoring, but is never an activation request.
  func applicationReady() {
    guard lifecycle == .launching else { return }
    lifecycle = .running
    do { try loadInitialRegistration() } catch {
      markVerification(error)
      stopRequests(problem: problem(error))
    }
    cancelMonitor = scheduleMonitor { [weak self] in self?.observeExit() }
    advance()
  }

  func submit(_ request: Request) {
    guard lifecycle != .terminating else { return }
    do { try Self.validate(request) } catch {
      report(.request(RequestReport(request: request, result: .notPerformed(problem(error)))))
      return
    }
    queue.append(Pending(request: request))
    advance()
  }

  func settingsOpened() {
    guard lifecycle != .terminating, settingsState != .editing else { return }
    settingsState = .editing
    settingsRevision += 1
  }

  func settingsClosed(_ result: SettingsResult) {
    guard lifecycle != .terminating, settingsState != .closed else { return }
    settingsState = .closed
    settingsRevision += 1
    if case .cancelled = result { cancelRequests(reason: .settingsCancelled) }
    advance()
  }

  /// Reports reserve their own presentation. Explicit confirmation dialogs reserve one here.
  func presentationOpened() -> PresentationID {
    let id = PresentationID()
    presentations.insert(id)
    return id
  }

  func presentationClosed(_ id: PresentationID) {
    guard presentations.remove(id) != nil else { return }
    advance()
  }

  func requestTermination(_ intent: TerminationIntent) -> TerminationDecision {
    if lifecycle == .terminating { return .allow }
    switch intent {
    case .automatic:
      guard canTerminateAutomatically else { return .cancel }
    case .userRequested:
      guard operation == nil else {
        report(.quitRefused)
        return .cancel
      }
    }
    lifecycle = .terminating
    settingsRevision += 1
    cancelMonitor?()
    cancelMonitor = nil
    cancelRequests(reason: .managerQuit)
    return .allow
  }

  private var canTerminateAutomatically: Bool {
    lifecycle == .running && operation == nil && queue.isEmpty && registrationIsEmpty
      && settingsState == .closed && presentations.isEmpty
  }

  /// Called only after state commits. The one operation slot remains occupied across awaits.
  private func advance() {
    guard lifecycle == .running else { return }
    if operation == nil, settingsState == .closed, presentations.isEmpty, !queue.isEmpty {
      operation = .resolving
      Task { await processNext() }
    } else if canTerminateAutomatically, !terminationNotificationQueued {
      terminationNotificationQueued = true
      enqueue(.terminationSuggested)
    }
  }

  private func processNext() async {
    defer {
      operation = nil
      unconfirmedOperation = nil
      advance()
    }
    guard settingsState == .closed, presentations.isEmpty, let pending = queue.first else { return }
    let revision = settingsRevision
    let reconciliation: RegistrationReconciliation
    do {
      try Self.validate(pending.request)
      reconciliation = try await reconcileRegistration()
    } catch {
      if requiresVerification {
        stopRequests(problem: problem(error))
      } else {
        queue.removeFirst()
        report(
          .request(RequestReport(request: pending.request, result: .notPerformed(problem(error)))))
      }
      return
    }
    guard preparationIsCurrent(pending, revision: revision) else { return }
    let target: RegistrationTarget?
    switch reconciliation {
    case .empty: target = nil
    case .verify(let value): target = value
    }
    let selected: Dependencies?
    if target == nil {
      do {
        selected = try await resolveDependencies()
      } catch {
        guard preparationIsCurrent(pending, revision: revision) else { return }
        settingsState = .required
        enqueue(.settingsRequired(problem(error)), settingsRevision: revision)
        return
      }
      guard preparationIsCurrent(pending, revision: revision) else { return }
    } else {
      selected = nil
    }
    do { try Self.validate(pending.request) } catch {
      queue.removeFirst()
      report(
        .request(RequestReport(request: pending.request, result: .notPerformed(problem(error)))))
      return
    }
    queue.removeFirst()
    operation = .opening
    do {
      if let outcome = try await handle(pending.request, selected, target: target) {
        report(.request(RequestReport(request: pending.request, result: .completed(outcome))))
      } else {
        // A recovered waiting terminal ended. No files were sent; choose new settings next.
        queue.insert(pending, at: 0)
      }
    } catch {
      if requiresVerification {
        let current = unconfirmedOperation.map {
          UnconfirmedRequest(request: pending.request, operation: $0)
        }
        if current == nil { queue.insert(pending, at: 0) }
        stopRequests(current: current, problem: problem(error))
      } else {
        let result: RequestResult
        if let failure = error as? SessionFailure, failure.kind == .focus {
          result = .focusFailed(
            confirmed: pending.request.files.isEmpty ? .sessionReady : .filesDelivered,
            problem: problem(error))
        } else {
          result = .notPerformed(problem(error))
        }
        report(.request(RequestReport(request: pending.request, result: result)))
      }
    }
  }

  private func preparationIsCurrent(_ pending: Pending, revision: Int) -> Bool {
    lifecycle == .running && settingsState == .closed && settingsRevision == revision
      && presentations.isEmpty && queue.first?.id == pending.id
  }

  private func loadInitialRegistration() throws {
    do {
      if let record = try store.load() {
        registrationState = .tracked(.loaded(record))
      } else {
        registrationState = .empty
      }
    } catch {
      registrationState = .needsVerification(evidence, issue: .unreadable(problem(error)))
      throw error
    }
  }

  private func readRegistration() throws -> Registration? {
    do { return try store.load() } catch {
      // Preserve stronger unresolved commit/removal/conflict causes alongside the same evidence.
      switch registrationState {
      case .needsVerification(_, .saveUnconfirmed),
        .needsVerification(_, .removalUnconfirmed), .needsVerification(_, .conflict):
        break
      default: registrationState = .needsVerification(evidence, issue: .unreadable(problem(error)))
      }
      throw error
    }
  }

  private func markVerification(_ error: any Error) {
    // A later platform failure must not erase an unconfirmed commit or its candidate.
    guard !requiresVerification else { return }
    registrationState = .needsVerification(evidence, issue: .verification(problem(error)))
  }

  /// Compares clues without publishing a merged session or treating readback as a commit.
  private func verificationTarget(reading disk: Registration?) throws -> RegistrationTarget? {
    var clues = registrationClues
    if let disk, !clues.contains(disk) { clues.append(disk) }
    // Conflict-only identities can outlive disk. They remain verification clues, never a
    // published baseline, and must agree with every other retained record below.
    guard var target = evidence.candidate ?? evidence.baseline?.record ?? disk ?? clues.first else {
      return nil
    }
    for clue in clues {
      guard RegistrationKey(clue) == RegistrationKey(target),
        clue.ghostty == nil || target.ghostty == nil || clue.ghostty == target.ghostty,
        clue.editor == nil || target.editor == nil || clue.editor == target.editor,
        clue.terminalID == nil || target.terminalID == nil || clue.terminalID == target.terminalID
      else {
        let conflict = RegistrationConflict(records: clues)
        registrationState = .needsVerification(evidence, issue: .conflict(conflict))
        throw conflict
      }
      target.ghostty = target.ghostty ?? clue.ghostty
      target.editor = target.editor ?? clue.editor
      target.terminalID = target.terminalID ?? clue.terminalID
    }
    // A preparing baseline cannot erase evidence that creation might have started.
    // The target still needs platform verification; this is not a phase-based publication.
    if target.phase == .preparing, clues.contains(where: { $0.phase != .preparing }) {
      target.phase = .starting
    }
    // Retain compatible identity clues for protection if the next platform query fails.
    // This candidate is only a verification target; no effects are authorized by it.
    if evidence.records.isEmpty, let disk {
      registrationState = .tracked(.loaded(disk))
    }
    if target != registration {
      var retained = evidence
      retained.candidate = target
      let issue: RegistrationIssue
      if case .needsVerification(_, let existing) = registrationState {
        issue = existing
      } else {
        issue = .verification(Problem(detail: "登记线索需要重新核验。"))
      }
      registrationState = .needsVerification(retained, issue: issue)
    }
    return RegistrationTarget(record: target)
  }

  private func reconcileRegistration() async throws -> RegistrationReconciliation {
    do {
      let disk = try readRegistration()
      guard let target = try verificationTarget(reading: disk) else {
        // An unreadable record cannot become known absent merely because no clues survived.
        if requiresVerification {
          throw AppFailure.message("缺少可核验的会话身份，请检查旧会话后使用恢复。")
        }
        registrationState = .empty
        return .empty
      }
      let record = target.record
      if record.phase == .preparing, record.ghostty == nil,
        record.terminalID == nil, record.editor == nil
      {
        guard case .removed = try await removeRegistration(.finishedSession) else {
          throw AppFailure.message("编辑器实例仍在运行，登记尚未清理。")
        }
        return .empty
      }
      if let editor = record.editor, try process(editor.pid) != editor {
        guard case .removed = try await removeRegistration(.finishedSession) else {
          throw AppFailure.message("编辑器实例仍在运行，登记尚未清理。")
        }
        return .empty
      }
      return .verify(target)
    } catch {
      markVerification(error)
      throw error
    }
  }

  /// A nil result retries only after a positively ended, interrupted startup was cleaned up.
  private func handle(
    _ request: Request, _ selected: Dependencies?, target: RegistrationTarget?
  ) async throws -> Outcome? {
    guard let record = target?.record else {
      guard let selected else { return nil }
      return try await create(request, selected)
    }
    do { try await ghostty.authorize(record.dependencies) } catch {
      markVerification(error)
      throw error
    }
    do {
      if record.phase != .ready, try finishClosedStartup(record) { return nil }
    } catch {
      markVerification(error)
      throw error
    }
    do {
      let identity = try await connect(record, record.dependencies)
      if !request.files.isEmpty {
        unconfirmedOperation = .delivery
        try await neovim.deliver(
          request.files, endpoint: record.endpoint, executable: record.dependencies.neovim)
        try await waitForReceipt(
          request.files, record: record, identity: identity, selected: record.dependencies)
        unconfirmedOperation = nil
      }
    } catch {
      markVerification(error)
      throw error
    }
    guard let confirmed = registration else { throw AppFailure.message("登记已消失。") }
    try await focus(confirmed, record.dependencies)
    return request.files.isEmpty ? .focused : .opened
  }

  private func beginRegistration(using selected: Dependencies) throws -> Registration {
    guard registrationIsEmpty else { throw AppFailure.message("旧会话尚未完成核验。") }
    do {
      if let disk = try readRegistration() { throw registrationConflict(with: disk) }
    } catch {
      markVerification(error)
      throw error
    }
    // Allocation has not attempted a commit and does not imply a possible terminal creation.
    let record = try store.allocate(using: selected)
    return try commitRegistration(record, step: .preparing)
  }

  @discardableResult
  private func advanceRegistration(_ advance: RegistrationAdvance, expecting key: RegistrationKey)
    throws -> Registration
  {
    guard var candidate = evidence.candidate ?? evidence.baseline?.record,
      RegistrationKey(candidate) == key
    else {
      let conflict = RegistrationConflict(records: evidence.records)
      registrationState = .needsVerification(evidence, issue: .conflict(conflict))
      throw conflict
    }
    let step: RegistrationStep
    switch advance {
    case .starting(let application):
      guard candidate.ghostty == nil || candidate.ghostty == application else {
        var observed = candidate
        observed.ghostty = application
        throw registrationConflict(with: observed)
      }
      candidate.ghostty = application
      candidate.phase = .starting
      step = .starting
    case .terminalCreated(let terminal), .associationVerified(let terminal):
      guard candidate.ghostty != nil,
        candidate.terminalID == nil || candidate.terminalID == terminal.id
      else {
        var observed = candidate
        observed.terminalID = terminal.id
        throw registrationConflict(with: observed)
      }
      candidate.terminalID = terminal.id
      if case .associationVerified = advance {
        guard candidate.editor != nil else { throw AppFailure.message("编辑器身份尚未确认。") }
        candidate.phase = .ready
        step = .associationVerified
      } else {
        step = .terminalCreated
      }
    case .editorIdentified(let editor):
      guard candidate.editor == nil || candidate.editor == editor else {
        var observed = candidate
        observed.editor = editor
        throw registrationConflict(with: observed)
      }
      candidate.editor = editor
      step = .editorIdentified
    }
    // Remember the newly observed identity before reading disk: even a failed read must
    // not erase a live editor or a terminal reply that the adapter has already confirmed.
    var retained = evidence
    retained.candidate = candidate
    let issue: RegistrationIssue
    if case .needsVerification(_, let existing) = registrationState {
      issue = existing
    } else {
      issue = .verification(Problem(detail: "已观察的会话身份尚未提交。"))
    }
    registrationState = .needsVerification(retained, issue: issue)
    guard let target = try verificationTarget(reading: readRegistration()) else {
      throw AppFailure.message("缺少可核验的会话身份。")
    }
    return try commitRegistration(target.record, step: step)
  }

  private func commitRegistration(_ candidate: Registration, step: RegistrationStep) throws
    -> Registration
  {
    do { try store.save(candidate) } catch {
      var retained = evidence
      retained.candidate = candidate
      registrationState = .needsVerification(
        retained, issue: .saveUnconfirmed(step, problem(error)))
      throw RegistrationCommitFailure(underlying: error)
    }
    registrationState = .tracked(.committed(candidate))
    return candidate
  }

  private func problem(_ error: any Error) -> Problem {
    Problem(detail: error.localizedDescription)
  }

  private func report(_ value: Report) {
    enqueue(.report(value, presentation: presentationOpened()))
  }

  private func stopRequests(current: UnconfirmedRequest? = nil, problem: Problem) {
    let remaining = queue.map(\.request)
    queue.removeAll()
    report(.stopped(StopReport(current: current, notProcessed: remaining, problem: problem)))
  }

  private func cancelRequests(reason: CancellationReason) {
    guard !queue.isEmpty else { return }
    let cancelled = queue.map(\.request)
    queue.removeAll()
    report(.cancelled(cancelled, reason: reason))
  }

  /// Serial delivery prevents nested modal alerts; callbacks may safely reenter Session.
  private func enqueue(_ event: Event, settingsRevision: Int? = nil) {
    notifications.append(Notification(event: event, settingsRevision: settingsRevision))
    guard !notifying else { return }
    notifying = true
    Task { [weak self] in
      guard let self else { return }
      while !notifications.isEmpty {
        let next = notifications.removeFirst()
        if let revision = next.settingsRevision,
          revision != self.settingsRevision || settingsState != .required
        {
          continue
        }
        if case .terminationSuggested = next.event {
          terminationNotificationQueued = false
          guard canTerminateAutomatically else { continue }
        }
        notify(next.event)
      }
      notifying = false
    }
  }

  private static func scheduleTimer(_ tick: @escaping @MainActor () -> Void)
    -> @MainActor () -> Void
  {
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      Task { @MainActor in tick() }
    }
    return { timer.invalidate() }
  }

  private func observeExit() {
    guard lifecycle == .running, operation == nil else { return }
    // NSAppleScript may pump a nested event loop even though closeFinished is synchronous.
    operation = .observing
    defer {
      operation = nil
      advance()
    }
    do {
      // Unconfirmed commits are never retried or removed by background observation.
      guard canObserveExit else { return }
      if let record = registration, let editor = record.editor, try process(editor.pid) != editor {
        try completeRemoval(.finishedSession, target: RegistrationTarget(record: record))
      }
    } catch {
      // Preserve unknown observations; a later explicit request reports the problem.
    }
  }

  func forgetAfterUserConfirmation() {
    guard lifecycle != .terminating else { return }
    guard operation == nil, queue.isEmpty else {
      report(.recovery(.refused(.busy)))
      return
    }
    operation = .recovering
    Task {
      let result: RecoveryResult
      do { result = try await forget() } catch { result = .failed(problem(error)) }
      report(.recovery(result))
      operation = nil
      advance()
    }
  }

  private func forget() async throws -> RecoveryResult {
    switch try await removeRegistration(.userConfirmed) {
    case .removed: .forgotten
    case .refused(let reason): .refused(reason)
    }
  }

  /// Explicit recovery alone may discard an unreadable record. Known identities still protect it.
  private func removeRegistration(_ mode: RegistrationRemoval) async throws
    -> RegistrationRemovalResult
  {
    let disk: Registration?
    switch mode {
    case .finishedSession: disk = try readRegistration()
    case .userConfirmed: disk = try? store.load()
    }
    let target = try verificationTarget(reading: disk)
    if let record = target?.record {
      if let editor = record.editor {
        if try process(editor.pid) == editor { return .refused(.editorStillRunning) }
      } else if case .userConfirmed = mode {
        if (try? await neovim.identify(
          endpoint: record.endpoint, executable: record.dependencies.neovim, timeout: 2)) != nil
        {
          return .refused(.endpointStillResponding)
        }
      }
    }
    guard try completeRemoval(mode, target: target) else {
      throw AppFailure.message("目前无法安全关闭专用终端；请检查终端，登记尚未清理。")
    }
    return .removed
  }

  private func registrationConflict(with observed: Registration) -> RegistrationConflict {
    var records = registrationClues
    if !records.contains(observed) { records.append(observed) }
    let conflict = RegistrationConflict(records: records)
    registrationState = .needsVerification(evidence, issue: .conflict(conflict))
    return conflict
  }

  /// A new readable record is never covered by confirmation of an unreadable or older record.
  private func checkRemovalTarget(_ target: RegistrationTarget?, mode: RegistrationRemoval) throws {
    let disk: Registration?
    switch mode {
    case .finishedSession: disk = try readRegistration()
    case .userConfirmed: disk = try? store.load()
    }
    if let disk {
      guard let target else { throw registrationConflict(with: disk) }
      _ = try verificationTarget(reading: disk)
      let expected = target.record
      guard RegistrationKey(disk) == RegistrationKey(expected),
        disk.editor == nil || disk.editor == expected.editor,
        disk.ghostty == nil || disk.ghostty == expected.ghostty,
        disk.terminalID == nil || disk.terminalID == expected.terminalID
      else { throw registrationConflict(with: disk) }
    }
    if let editor = target?.record.editor, try process(editor.pid) == editor {
      throw AppFailure.message("已确认的编辑器实例仍在运行，登记尚未清理。")
    }
  }

  /// Final read and deletion do not suspend, under both the instance lock and operation slot.
  @discardableResult
  private func completeRemoval(_ mode: RegistrationRemoval, target: RegistrationTarget?) throws
    -> Bool
  {
    try checkRemovalTarget(target, mode: mode)
    if case .finishedSession = mode {
      guard let target else { throw AppFailure.message("缺少待清理的会话代次。") }
      // A terminal still running (including Quick Terminal protection) is not a failed unlink.
      guard try closeFinishedTerminal(target.record) else { return false }
    }
    do {
      // NSAppleScript can run a nested event loop. Check again after terminal closing.
      try checkRemovalTarget(target, mode: mode)
      switch mode {
      case .finishedSession:
        guard let target else { throw AppFailure.message("缺少待清理的会话代次。") }
        try store.clear(target.record.id)
      case .userConfirmed: try store.forget()
      }
      registrationState = .empty
      return true
    } catch {
      if let conflict = error as? RegistrationConflict {
        registrationState = .needsVerification(evidence, issue: .conflict(conflict))
      } else {
        registrationState = .needsVerification(evidence, issue: .removalUnconfirmed(problem(error)))
      }
      throw error
    }
  }

  private static func validate(_ request: Request) throws {
    if case .files(let files) = request, files.isEmpty {
      throw SessionFailure(kind: .input, message: "没有收到文件。")
    }
    let invalid = request.files.filter { url in
      guard url.isFileURL else { return true }
      var info = stat()
      return stat(url.path, &info) != 0 || info.st_mode & S_IFMT != S_IFREG
        || access(url.path, R_OK) != 0
    }
    if !invalid.isEmpty {
      throw SessionFailure(
        kind: .input,
        message: "整批文件尚未投递。以下项目不是可读的本地普通文件：\n"
          + invalid.map(\.path).joined(separator: "\n"))
    }
  }

  /// Preflight has no terminal side effects, so an exiting Ghostty can be prepared again safely.
  private func prepareForCreation(_ selected: Dependencies) async throws -> ProcessIdentity {
    var deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
    var lastError: any Error = AppFailure.timedOut
    while ProcessInfo.processInfo.systemUptime < deadline {
      let application = try await ghostty.prepare(selected, deadline: deadline)
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw AppFailure.timedOut
      }
      let consentStarted = ProcessInfo.processInfo.systemUptime
      do {
        // Human consent is unbounded, including when a restart requires another permission check.
        defer { deadline += ProcessInfo.processInfo.systemUptime - consentStarted }
        try await ghostty.authorize(selected)
        guard try process(application.pid) == application else {
          throw AppFailure.message("准备期间 Ghostty 实例已改变。")
        }
        return application
      } catch {
        if let failure = error as? GhosttyFailure,
          failure.code == -1743 || failure.code == -1744
        {
          throw error
        }
        lastError = error
      }
      try await sleep()
    }
    throw lastError
  }

  private func create(_ request: Request, _ selected: Dependencies) async throws -> Outcome {
    let application: ProcessIdentity
    do {
      application = try await prepareForCreation(selected)
    } catch {
      throw SessionFailure(kind: .unavailable, message: "未创建会话：\(error.localizedDescription)")
    }
    let record: Registration
    do { record = try beginRegistration(using: selected) } catch let error
      as RegistrationCommitFailure
    {
      throw error
    } catch {
      throw SessionFailure(kind: .unavailable, message: "未创建会话：\(error.localizedDescription)")
    }
    let key = RegistrationKey(record)
    do {
      let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
      try advanceRegistration(.starting(ghostty: application), expecting: key)
      let directory =
        request.files.first?.deletingLastPathComponent()
        ?? FileManager.default.homeDirectoryForCurrentUser
      var arguments = [selected.neovim.path, "--listen", record.endpoint.path]
      if !request.files.isEmpty { arguments += ["--"] + request.files.map(\.path) }
      // Ghostty adds exec when starting the configured command.
      let command = arguments.map(CommandRunner.quote).joined(separator: " ")
      let timeout = try remaining(deadline, limit: 3)
      unconfirmedOperation = .creation
      _ = try await ghostty.create(
        selected, command: command, directory: directory, timeout: timeout,
        onCreated: { terminal in
          try self.advanceRegistration(.terminalCreated(terminal), expecting: key)
        })
      var lastError: any Error = AppFailure.timedOut
      while ProcessInfo.processInfo.systemUptime < deadline {
        do {
          guard let current = registration else { throw AppFailure.message("登记已消失。") }
          let identity = try await connect(current, selected, deadline: deadline)
          try await neovim.verify(
            request.files, endpoint: record.endpoint, executable: selected.neovim,
            pid: identity.pid,
            timeout: remaining(deadline, limit: 2)
          )
          unconfirmedOperation = nil
          guard let confirmed = registration else { throw AppFailure.message("登记已消失。") }
          try await focus(
            confirmed, selected, deadline: deadline)
          return request.files.isEmpty ? .focused : .opened
        } catch {
          if error is RegistrationCommitFailure || requiresVerification { throw error }
          if let current = registration, try finishClosedStartup(current) { return .closed }
          if let error = error as? SessionFailure, error.kind == .focus { throw error }
          lastError = error
        }
        try await sleep()
      }
      throw lastError
    } catch let error as SessionFailure where error.kind == .focus { throw error } catch {
      markVerification(error)
      throw SessionFailure(
        kind: .uncertain,
        message: error.localizedDescription)
    }
  }

  private func connect(
    _ record: Registration, _ selected: Dependencies, deadline: TimeInterval? = nil
  ) async throws
    -> EditorIdentity
  {
    guard let application = record.ghostty, try process(application.pid) == application else {
      throw AppFailure.message("登记的 Ghostty 进程实例已改变或无法确认。")
    }
    let identity = try await neovim.identify(
      endpoint: record.endpoint, executable: selected.neovim, timeout: remaining(deadline, limit: 2)
    )
    guard let actual = try process(identity.pid) else {
      throw AppFailure.message("Neovim RPC 进程身份改变。")
    }
    let key = RegistrationKey(record)
    // Preserve a positively identified editor even if terminal association fails next.
    try advanceRegistration(.editorIdentified(actual), expecting: key)
    guard try process(application.pid) == application else {
      throw AppFailure.message("核验期间 Ghostty 进程实例已改变。")
    }
    let terminal = try await ghostty.terminal(
      selected, id: record.terminalID, matching: identity.terminalPIDs,
      timeout: remaining(deadline, limit: 2))
    _ = try remaining(deadline, limit: 1)
    guard try process(application.pid) == application else {
      throw AppFailure.message("核验期间 Ghostty 进程实例已改变。")
    }
    try advanceRegistration(.associationVerified(terminal), expecting: key)
    return identity
  }

  private func waitForReceipt(
    _ files: [URL], record: Registration, identity: EditorIdentity, selected: Dependencies
  ) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + min(startupTimeout, 5)
    var lastError: any Error = AppFailure.timedOut
    repeat {
      do {
        try await neovim.verify(
          files, endpoint: record.endpoint, executable: selected.neovim, pid: identity.pid,
          timeout: remaining(deadline, limit: 2))
        _ = try remaining(deadline, limit: 1)
        return
      } catch { lastError = error }
      try await sleep()
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw lastError
  }

  private func focus(
    _ record: Registration, _ selected: Dependencies,
    deadline: TimeInterval? = nil
  )
    async throws
  {
    do {
      guard let application = record.ghostty, try process(application.pid) == application,
        let terminalID = record.terminalID
      else { throw AppFailure.message("目标终端身份已失效。") }
      try await ghostty.focus(
        selected, terminalID: terminalID, timeout: remaining(deadline, limit: 2))
      _ = try remaining(deadline, limit: 1)
    } catch {
      throw SessionFailure(
        kind: .focus,
        message: error.localizedDescription)
    }
  }

  private func remaining(_ deadline: TimeInterval?, limit: TimeInterval) throws -> TimeInterval {
    guard let deadline else { return limit }
    let value = deadline - ProcessInfo.processInfo.systemUptime
    guard value > 0 else { throw AppFailure.timedOut }
    return min(value, limit)
  }

  private func sleep() async throws {
    try await Task.sleep(for: .seconds(pollInterval))
  }

  /// No editor identity is not proof of exit; interrupted startup also needs terminal evidence.
  private func finishClosedStartup(_ record: Registration) throws -> Bool {
    guard record.terminalID != nil else { return false }
    if let editor = record.editor {
      guard try process(editor.pid) != editor else { return false }
    }
    return try completeRemoval(.finishedSession, target: RegistrationTarget(record: record))
  }

  private func closeFinishedTerminal(_ record: Registration) throws -> Bool {
    if record.editor == nil {
      if record.phase == .preparing, record.ghostty == nil, record.terminalID == nil { return true }
      guard record.ghostty != nil, record.terminalID != nil else {
        throw AppFailure.message("缺少启动终端或原 Ghostty 身份，不能确认会话已结束。")
      }
      var info = stat()
      if lstat(record.endpoint.path, &info) == 0 { return false }
      guard errno == ENOENT else { throw AppFailure.message("无法确认启动中的 RPC socket 是否已消失。") }
    }
    if let application = record.ghostty, try process(application.pid) == application,
      let terminalID = record.terminalID
    {
      return try ghostty.closeFinished(record.dependencies, terminalID: terminalID)
    }
    return true
  }
}
