import Darwin
import Foundation
import Testing

@testable import Neovlet

@Suite @MainActor struct SessionTests {
  @Test func activationCreatesAnOwnedSession() async throws {
    let fixture = SessionFixture()
    let result = try await fixture.perform(.activate, using: fixture.dependencies)
    #expect(result == .focused)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.ghostty.focuses == 1)
    #expect(fixture.store.record?.phase == .ready)
  }

  @Test func authorizationWaitDoesNotSpendTheStartupBudgetOrRegisterACreation() async throws {
    let fixture = SessionFixture()
    let session = fixture.makeSession(startupTimeout: 0.1)
    fixture.ghostty.pauseAuthorization = true
    let opening = Task {
      try await fixture.perform(on: session, .activate, using: fixture.dependencies)
    }
    try await eventually { fixture.ghostty.authorizationGate != nil }
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.creates == 0)
    #expect(session.requestTermination(.userRequested) == .cancel)
    try await Task.sleep(for: .milliseconds(150))
    fixture.ghostty.authorizationGate?.resume()
    #expect(try await opening.value == .focused)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.store.record?.phase == .ready)
  }

  @Test func deniedAuthorizationLeavesNoRegistrationAndAnExplicitRetryCanCreate() async throws {
    let fixture = SessionFixture()
    var attempts = 0
    fixture.ghostty.onAuthorize = { attempts += 1 }
    fixture.ghostty.authorizationFailure = GhosttyFailure(code: -1743, detail: "permission denied")
    do {
      _ = try await fixture.perform(.activate, using: fixture.dependencies)
      Issue.record("Expected authorization failure")
    } catch let error as ReportFailure {
      #expect(error.kind == .unavailable)
    }
    #expect(fixture.store.record == nil)
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.creates == 0)
    #expect(attempts == 1)
    fixture.ghostty.authorizationFailure = nil
    #expect(try await fixture.perform(.activate, using: fixture.dependencies) == .focused)
    #expect(fixture.ghostty.creates == 1)
  }

  @Test func aGhosttyExitDuringPreflightRetriesBeforeRegisteringOrCreating() async throws {
    let fixture = SessionFixture()
    var attempts = 0
    fixture.ghostty.onAuthorize = {
      attempts += 1
      #expect(fixture.store.record == nil)
      #expect(fixture.ghostty.creates == 0)
      if attempts == 1 { throw AppFailure.message("Ghostty exited during authorization") }
    }
    let file = URL(fileURLWithPath: #filePath)
    #expect(try await fixture.perform(.files([file]), using: fixture.dependencies) == .opened)
    #expect(attempts == 2)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.neovim.deliveries.isEmpty)
    #expect(fixture.ghostty.launchCommand?.hasSuffix(CommandRunner.quote(file.path)) == true)
  }

  @Test func repeatedPreflightFailureStopsWithoutCreatingARegistration() async throws {
    let fixture = SessionFixture()
    let session = fixture.makeSession(startupTimeout: 0.02)
    fixture.ghostty.onAuthorize = { throw AppFailure.message("Ghostty still exiting") }
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(on: session, .activate, using: fixture.dependencies)
    }
    #expect(fixture.store.record == nil)
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.creates == 0)
  }

  @Test func uncertainCreationStillRetainsItsRegistrationAndDoesNotCreateAgain() async throws {
    let fixture = SessionFixture()
    fixture.ghostty.creationFails = true
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(.activate, using: fixture.dependencies)
    }
    let record = try #require(fixture.store.record)
    #expect(record.phase == .starting)
    fixture.neovim.identificationFails = true
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(.activate, using: fixture.dependencies)
    }
    #expect(fixture.store.record == record)
    #expect(fixture.ghostty.creates == 1)
  }

  @Test func permissionFailureOnAnExistingSessionDoesNotDeliverAndCanBeRetried() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let record = try #require(fixture.store.record)
    fixture.ghostty.authorizationFailure = GhosttyFailure(code: -1743, detail: "permission denied")
    let file = URL(fileURLWithPath: #filePath)
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(.files([file]), using: fixture.dependencies)
    }
    #expect(fixture.store.record == record)
    #expect(fixture.neovim.deliveries.isEmpty)
    fixture.ghostty.authorizationFailure = nil
    #expect(try await fixture.perform(.files([file]), using: fixture.dependencies) == .opened)
    #expect(fixture.neovim.deliveries == [[file]])
    #expect(fixture.ghostty.creates == 1)
  }

  @Test func launchArgumentsSurviveGhosttysExecWrapper() async throws {
    let fixture = SessionFixture()
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake nvim")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let file = directory.appendingPathComponent("中文 ' $(literal); file.txt")
    try Data().write(to: file)
    let dependencies = Dependencies(
      ghostty: fixture.dependencies.ghostty, neovim: executable,
      ghosttyIdentifier: fixture.dependencies.ghosttyIdentifier)
    _ = try await fixture.perform(.files([file]), using: dependencies)
    let command = try #require(fixture.ghostty.launchCommand)
    // Ghostty adds the shell's exec; the configured command must start with the executable.
    let result = try await CommandRunner().run(["/bin/sh", "-c", "exec " + command])
    #expect(result.status == 0)
    #expect(result.output == "--listen\n/private/tmp/test.sock\n--\n\(file.path)\n")
  }

  @Test func terminalAssociationUsesTTYInsteadOfTheLoginWrapperPID() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    try #require(openpty(&master, &slave, nil, nil, nil) == 0)
    defer {
      close(master)
      close(slave)
    }
    let path = try #require(ttyname(slave))
    var info = stat()
    try #require(fstat(slave, &info) == 0)
    let terminal = OwnedTerminal(id: "test", pid: 123, tty: String(cString: path))
    #expect(try terminal.containsClient(on: [info.st_rdev]))
    #expect(try !terminal.containsClient(on: []))
  }

  @Test @MainActor func incompleteRecoveryCannotForgetAnEditorThatWasConfirmedAlive() async throws {
    let fixture = SessionFixture()
    fixture.store.record = Registration(
      id: UUID(), endpoint: URL(fileURLWithPath: "/private/tmp/test.sock"),
      dependencies: fixture.dependencies, phase: .starting,
      ghostty: fixture.application)
    fixture.ghostty.lookupFails = true
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(.activate, using: fixture.dependencies)
    }
    await #expect(throws: AppFailure.self) {
      try await fixture.forget()
    }
    #expect(fixture.store.record != nil)
    #expect(fixture.ghostty.creates == 0)
  }

  @Test @MainActor func requestsDuringCreationUseOneSessionAndRetainOrder() async throws {
    let fixture = SessionFixture()
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    try Data().write(to: first)
    try Data().write(to: second)
    fixture.ghostty.pauseCreation = true
    let creating = Task { try await fixture.perform(.activate, using: fixture.dependencies) }
    try await eventually { fixture.ghostty.creationGate != nil }
    let opening = Task {
      _ = try await fixture.perform(.files([first]), using: fixture.dependencies)
      _ = try await fixture.perform(.files([second]), using: fixture.dependencies)
    }
    await Task.yield()
    fixture.ghostty.creationGate?.resume()
    _ = try await creating.value
    try await opening.value
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.neovim.deliveries == [[first], [second]])
  }

  @Test func recoveryCleanupSerializesIncomingOpenRequests() async throws {
    let fixture = SessionFixture()
    fixture.store.record = Registration(
      id: UUID(), endpoint: URL(fileURLWithPath: "/private/tmp/test.sock"),
      dependencies: fixture.dependencies, phase: .starting, ghostty: fixture.application)
    fixture.neovim.pauseIdentification = true
    let cleanup = Task { try await fixture.forget() }
    try await eventually { fixture.neovim.identificationGate != nil }
    #expect(fixture.session.requestTermination(.userRequested) == .cancel)
    let opening = Task {
      try await fixture.perform(
        .files([URL(fileURLWithPath: #filePath)]), using: fixture.dependencies)
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.neovim.deliveries.isEmpty)
    fixture.neovim.identificationGate?.resume(throwing: AppFailure.timedOut)
    try await cleanup.value
    #expect(try await opening.value == .opened)
    #expect(fixture.store.record?.phase == .ready)
    #expect(fixture.store.record != nil)
  }

  @Test @MainActor func restartRestoresTheRegisteredSessionWithoutCreatingAnother() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let restarted = fixture.makeSession()
    _ = try await fixture.perform(on: restarted, .activate, using: fixture.dependencies)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.ghostty.focuses == 2)
  }

  @Test func changedSettingsApplyOnlyAfterTheRegisteredEditorEnds() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let changed = Dependencies(
      ghostty: URL(fileURLWithPath: "/Other/Ghostty.app"),
      neovim: URL(fileURLWithPath: "/other/nvim"), ghosttyIdentifier: "test.ghostty")
    let restarted = fixture.makeSession()
    _ = try await fixture.perform(on: restarted, .activate, using: changed)
    #expect(fixture.store.record?.dependencies == fixture.dependencies)
    #expect(fixture.ghostty.observedDependencies.last == fixture.dependencies)
    fixture.alive = false
    fixture.tick(restarted)
    fixture.alive = true
    _ = try await fixture.perform(on: restarted, .activate, using: changed)
    #expect(fixture.store.record?.dependencies == changed)
    #expect(fixture.ghostty.creates == 2)
  }

  @Test func preparationUsesTheStartupBudgetAndCannotCreateAfterItExpires() async throws {
    let fixture = SessionFixture()
    let session = fixture.makeSession(startupTimeout: 0.02)
    fixture.ghostty.preparationDelay = 0.03
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(on: session, .activate, using: fixture.dependencies)
    }
    #expect(fixture.ghostty.creates == 0)
    #expect(fixture.store.record == nil)
    #expect(fixture.store.record == nil)
  }

  @Test func editorExitingBeforeIdentificationFinishesCreationWithoutAnError() async throws {
    let fixture = SessionFixture()
    let session = fixture.makeSession()
    fixture.neovim.identificationFails = true
    fixture.ghostty.terminalFinished = true
    do {
      #expect(
        try await fixture.perform(on: session, .activate, using: fixture.dependencies) == .closed)
    } catch {
      Issue.record("已结束的专用终端不应被当作启动失败：\(error)")
    }
    #expect(fixture.store.record == nil)
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.closedTerminals == ["owned"])
    #expect(fixture.ghostty.creates == 1)
  }

  @Test func terminalIdentityIsSavedWhileEditorLaunchIsStillWaiting() async throws {
    let fixture = SessionFixture()
    fixture.ghostty.pauseCreation = true
    let opening = Task {
      try await fixture.perform(.activate, using: fixture.dependencies)
    }
    try await eventually { fixture.ghostty.creationGate != nil }
    #expect(fixture.store.record?.terminalID == "owned")
    #expect(fixture.store.record?.editor == nil)
    fixture.ghostty.creationGate?.resume()
    #expect(try await opening.value == .focused)
  }

  @Test func anExplicitRequestAfterAnAbortedLaunchCreatesWithoutReplayingOldFiles() async throws {
    let fixture = SessionFixture()
    let oldID = UUID()
    fixture.store.record = Registration(
      id: oldID, endpoint: URL(fileURLWithPath: "/private/tmp/test.sock"),
      dependencies: fixture.dependencies, phase: .starting,
      ghostty: fixture.application, terminalID: "owned")
    fixture.neovim.identificationFails = true
    fixture.ghostty.onCreate = { fixture.neovim.identificationFails = false }
    let file = URL(fileURLWithPath: #filePath)
    do {
      #expect(
        try await fixture.perform(.files([file]), using: fixture.dependencies) == .opened)
    } catch {
      Issue.record("已结束的等待终端应允许处理新的明确请求：\(error)")
    }
    #expect(fixture.store.record?.id != oldID)
    #expect(fixture.store.record?.phase == .ready)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.ghostty.launchCommand?.contains(CommandRunner.quote(file.path)) == true)
    #expect(fixture.neovim.deliveries.isEmpty)
  }

  @Test func aRunningTerminalWithUnconfirmedRPCIsNeverDiscarded() async throws {
    let fixture = SessionFixture()
    let session = fixture.makeSession(startupTimeout: 0.03)
    fixture.neovim.identificationFails = true
    fixture.ghostty.terminalFinished = false
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(on: session, .activate, using: fixture.dependencies)
    }
    #expect(fixture.store.record?.terminalID == "owned")
    #expect(fixture.lastStop(session) != nil)
    #expect(fixture.ghostty.closedTerminals.isEmpty)
  }

  @Test func startupContinuesPollingWhileItsTerminalIsRunningAndRPCBecomesReady() async throws {
    let fixture = SessionFixture()
    fixture.neovim.identificationFails = true
    fixture.ghostty.terminalFinished = false
    // The first failed RPC checks the known terminal. Its command is running, so keep waiting.
    fixture.ghostty.onClose = { fixture.neovim.identificationFails = false }
    #expect(try await fixture.perform(.activate, using: fixture.dependencies) == .focused)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.ghostty.focuses == 1)
    #expect(fixture.ghostty.closedTerminals.isEmpty)
    #expect(fixture.store.record?.phase == .ready)
  }

  @Test func editorExitingBetweenVerificationAndFocusFinishesWithoutAnError() async throws {
    let fixture = SessionFixture()
    fixture.neovim.onVerify = { fixture.alive = false }
    fixture.ghostty.focusFails = true
    #expect(try await fixture.perform(.activate, using: fixture.dependencies) == .closed)
    #expect(fixture.store.record == nil)
    #expect(fixture.store.record == nil)
  }

  @Test @MainActor func uncertainDeliveryDoesNotResendOrCreateAgain() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let file = URL(fileURLWithPath: #filePath)
    fixture.neovim.deliveryFails = true
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(.files([file]), using: fixture.dependencies)
    }
    #expect(fixture.neovim.deliveries == [[file]])
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.lastStop() != nil)
    #expect(fixture.store.record != nil)
  }

  @Test func anUncertainDeliveryCanStillBeFollowedByNormalExitObservation() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    fixture.neovim.deliveryFails = true
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(
        .files([URL(fileURLWithPath: #filePath)]), using: fixture.dependencies)
    }
    fixture.alive = false
    fixture.tick()
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.closedTerminals == ["owned"])
  }

  @Test @MainActor func focusFailureReportsDeliveredFilesWithoutReplayingThem() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    fixture.ghostty.focusFails = true
    do {
      _ = try await fixture.perform(
        .files([URL(fileURLWithPath: #filePath)]), using: fixture.dependencies)
      Issue.record("Expected focus failure")
    } catch let error as ReportFailure { #expect(error.kind == .focus) }
    #expect(fixture.neovim.deliveries.count == 1)
    #expect(fixture.store.record?.phase == .ready)
  }

  @Test @MainActor func invalidBatchHasNoCreationOrDeliverySideEffects() async throws {
    let fixture = SessionFixture()
    await #expect(throws: ReportFailure.self) {
      _ = try await fixture.perform(
        .files([
          URL(fileURLWithPath: #filePath), URL(fileURLWithPath: "/missing-neovlet-file"),
        ]),
        using: fixture.dependencies)
    }
    #expect(fixture.ghostty.creates == 0)
    #expect(fixture.neovim.deliveries.isEmpty)
    #expect(fixture.store.record == nil)
  }

  @Test @MainActor func normalEditorExitReleasesRegistration() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    fixture.alive = false
    fixture.tick()
    #expect(fixture.store.record == nil)
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.closedTerminals == ["owned"])
  }

  @Test func cleanupWaitsForTheOwnedTerminalCommandToFinish() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    fixture.alive = false
    fixture.ghostty.terminalFinished = false
    fixture.tick()
    #expect(fixture.store.record != nil)
    #expect(fixture.ghostty.closedTerminals.isEmpty)
    fixture.ghostty.terminalFinished = true
    fixture.tick()
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.closedTerminals == ["owned"])
  }

  @Test @MainActor func registrationWritesSurviveReopeningAndRejectOldGenerationCleanup() throws {
    let root = try testDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(namespace: UUID().uuidString, root: root)
    let dependencies = SessionFixture().dependencies
    let first = try store.allocate(using: dependencies)
    try store.save(first)
    let second = try store.allocate(using: dependencies)
    try store.save(second)
    #expect(throws: RegistrationConflict.self) { try store.clear(first.id) }
    #expect(try store.load() == second)
    #expect(throws: AppFailure.self) {
      _ = try SessionStore(namespace: store.directory.lastPathComponent, root: root)
    }
    try store.clear(second.id)
    #expect(try store.load() == nil)
    try FileManager.default.removeItem(at: store.socketDirectory)
  }

}

func testDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}

/// Adapts the event interface to convenient waits; production never uses an async open facade.
struct ReportFailure: Error {
  enum Kind { case unavailable, uncertain, focus }
  let kind: Kind
}

@MainActor final class SessionObserver {
  weak var session: Session?
  var reports: [Session.Report] = []
  var presentations: [Session.PresentationID] = []
  var settingsProblems: [Session.Problem] = []
  var terminationSuggestions = 0
  var acknowledge = true
  var tick: (@MainActor () -> Void)?
  var monitorCancelled = false
  var onEvent: ((Session.Event) -> Void)?

  func receive(_ event: Session.Event) {
    switch event {
    case .report(let report, let presentation):
      reports.append(report)
      presentations.append(presentation)
      if acknowledge { session?.presentationClosed(presentation) }
    case .settingsRequired(let problem): settingsProblems.append(problem)
    case .terminationSuggested: terminationSuggestions += 1
    }
    onEvent?(event)
  }
}

@MainActor final class SessionFixture {
  let dependencies = Dependencies(
    ghostty: URL(fileURLWithPath: "/Ghostty.app"), neovim: URL(fileURLWithPath: "/nvim"),
    ghosttyIdentifier: "test.ghostty")
  let application = ProcessIdentity(pid: 10, startedSeconds: 100, startedMicroseconds: 0)
  let editor = ProcessIdentity(pid: 20, startedSeconds: 200, startedMicroseconds: 0)
  let store = MemoryStore()
  let ghostty = TestGhostty()
  let neovim = TestNeovim()
  var alive = true
  var processProblem: (any Error)?
  var selectedDependencies: Dependencies?
  var resolve: (() async throws -> Dependencies)?
  var resolutions = 0
  private var observers: [ObjectIdentifier: SessionObserver] = [:]
  lazy var session = makeSession()

  func makeSession(
    startupTimeout: TimeInterval = 1, ready: Bool = true, store: (any SessionStoring)? = nil
  ) -> Session {
    let observer = SessionObserver()
    let session = Session(
      store: store ?? self.store, ghostty: ghostty, neovim: neovim,
      resolveDependencies: { [unowned self] in
        resolutions += 1
        if let resolve { return try await resolve() }
        return selectedDependencies ?? dependencies
      },
      process: { [unowned self] pid in
        if let processProblem { throw processProblem }
        if pid == 10 { return application }
        return pid == 20 && alive ? editor : nil
      }, startupTimeout: startupTimeout, pollInterval: 0.001,
      scheduleMonitor: { tick in
        observer.tick = tick
        return { observer.monitorCancelled = true }
      },
      notify: { [weak observer] event in observer?.receive(event) })
    observer.session = session
    observers[ObjectIdentifier(session)] = observer
    if ready { session.applicationReady() }
    return session
  }

  func observer(_ session: Session? = nil) -> SessionObserver {
    observers[ObjectIdentifier(session ?? self.session)]!
  }

  func tick(_ session: Session? = nil) { observer(session).tick?() }

  func lastStop(_ session: Session? = nil) -> Session.StopReport? {
    for report in observer(session).reports.reversed() {
      if case .stopped(let stopped) = report { return stopped }
    }
    return nil
  }

  func perform(
    on target: Session? = nil, _ request: Session.Request, using dependencies: Dependencies
  ) async throws -> Session.Outcome {
    let session = target ?? self.session
    selectedDependencies = dependencies
    let observer = observer(session)
    let start = observer.reports.count
    session.submit(request)
    try await eventually {
      observer.reports.dropFirst(start).contains { report in
        switch report {
        case .request(let result): result.request == request
        case .stopped(let stopped):
          stopped.current?.request == request || stopped.notProcessed.contains(request)
        default: false
        }
      }
    }
    for report in observer.reports.dropFirst(start) {
      switch report {
      case .request(let report) where report.request == request:
        switch report.result {
        case .completed(let outcome): return outcome
        case .notPerformed: throw ReportFailure(kind: .unavailable)
        case .focusFailed: throw ReportFailure(kind: .focus)
        }
      case .stopped(let stopped)
      where
        stopped.current?.request == request || stopped.notProcessed.contains(request):
        throw ReportFailure(kind: .uncertain)
      default: continue
      }
    }
    throw ReportFailure(kind: .uncertain)
  }

  func forget(on target: Session? = nil) async throws {
    let session = target ?? self.session
    let observer = observer(session)
    let start = observer.reports.count
    session.forgetAfterUserConfirmation()
    try await eventually {
      observer.reports.dropFirst(start).contains {
        if case .recovery = $0 { true } else { false }
      }
    }
    for report in observer.reports.dropFirst(start) {
      if case .recovery(let result) = report {
        if result != .forgotten { throw AppFailure.message("Recovery refused or failed") }
        return
      }
    }
  }
}

/// Bounded condition waits fail instead of leaving a broken continuation test hanging forever.
@MainActor func eventually(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() {
    guard ContinuousClock.now < deadline else { throw AppFailure.timedOut }
    try await Task.sleep(for: .milliseconds(1))
  }
}

@MainActor final class MemoryStore: SessionStoring {
  var record: Registration?
  var loadFails = false
  var allocationFails = false
  var forgetFails = false
  func load() throws -> Registration? {
    if loadFails { throw AppFailure.message("registration unreadable") }
    return record
  }
  func allocate(using dependencies: Dependencies) throws -> Registration {
    if allocationFails { throw AppFailure.message("allocation failed before save") }
    return Registration(
      id: UUID(), endpoint: URL(fileURLWithPath: "/private/tmp/test.sock"),
      dependencies: dependencies)
  }
  func save(_ registration: Registration) throws {
    record = registration
  }
  func clear(_ id: UUID) throws {
    if let record, record.id != id { throw RegistrationConflict(records: [record]) }
    record = nil
  }
  func forget() throws {
    if forgetFails { throw AppFailure.message("forget failed") }
    record = nil
  }
}

@MainActor final class TestGhostty: GhosttyAccess {
  var onCreate: (() -> Void)?
  var onClose: (() -> Void)?
  var onTerminal: (() -> Void)?
  var authorized = false
  var pauseAuthorization = false
  var authorizationFailure: (any Error)?
  var onAuthorize: (() throws -> Void)?
  var authorizationGate: CheckedContinuation<Void, Never>?
  var creationFails = false
  var terminalFinished = true
  var closedTerminals: [String] = []
  var launchCommand: String?
  var observedDependencies: [Dependencies] = []
  var preparationDelay: TimeInterval = 0
  var creates = 0
  var focuses = 0
  var lookupFails = false
  var focusFails = false
  var pauseCreation = false
  var creationGate: CheckedContinuation<Void, Never>?
  func authorize(_ dependencies: Dependencies) async throws {
    try onAuthorize?()
    if pauseAuthorization {
      pauseAuthorization = false
      await withCheckedContinuation { authorizationGate = $0 }
    }
    if let authorizationFailure { throw authorizationFailure }
    authorized = true
  }
  func prepare(_ dependencies: Dependencies, deadline: TimeInterval) async throws -> ProcessIdentity
  {
    try await Task.sleep(for: .seconds(preparationDelay))
    return ProcessIdentity(pid: 10, startedSeconds: 100, startedMicroseconds: 0)
  }
  func create(
    _ dependencies: Dependencies, command: String, directory: URL, timeout: TimeInterval,
    onCreated: (OwnedTerminal) throws -> Void
  )
    async throws
    -> OwnedTerminal
  {
    // Without preflight, the first create operation also has to wait for system consent.
    if !authorized { try await authorize(dependencies) }
    creates += 1
    if creationFails { throw AppFailure.timedOut }
    launchCommand = command
    let terminal = OwnedTerminal(id: "owned", pid: 21, tty: "/dev/test")
    try onCreated(terminal)
    if pauseCreation { await withCheckedContinuation { creationGate = $0 } }
    onCreate?()
    await Task.yield()
    return terminal
  }
  func terminal(
    _ dependencies: Dependencies, id: String?, matching pids: [Int32], timeout: TimeInterval
  ) async throws
    -> OwnedTerminal
  {
    observedDependencies.append(dependencies)
    if lookupFails { throw AppFailure.message("terminal unavailable") }
    onTerminal?()
    return OwnedTerminal(id: "owned", pid: 21, tty: "/dev/test")
  }
  func focus(_ dependencies: Dependencies, terminalID: String, timeout: TimeInterval) async throws {
    if focusFails { throw AppFailure.message("focus failed") }
    focuses += 1
  }
  func closeFinished(_ dependencies: Dependencies, terminalID: String) throws -> Bool {
    onClose?()
    if !terminalFinished { return false }
    closedTerminals.append(terminalID)
    return true
  }
}

@MainActor final class TestNeovim: NeovimAccess {
  var onVerify: (() -> Void)?
  var onIdentify: (() -> Void)?
  var identificationFails = false
  var pauseIdentification = false
  var identificationGate: CheckedContinuation<EditorIdentity, any Error>?
  var deliveries: [[URL]] = []
  var deliveryFails = false
  var pauseDelivery = false
  var deliveryGate: CheckedContinuation<Void, Never>?
  func identify(endpoint: URL, executable: URL, timeout: TimeInterval) async throws
    -> EditorIdentity
  {
    if identificationFails { throw AppFailure.timedOut }
    if pauseIdentification {
      pauseIdentification = false
      return try await withCheckedThrowingContinuation { identificationGate = $0 }
    }
    onIdentify?()
    return EditorIdentity(pid: 20, endpoint: endpoint.path, terminalPIDs: [21])
  }
  func deliver(_ files: [URL], endpoint: URL, executable: URL) async throws {
    deliveries.append(files)
    if pauseDelivery {
      pauseDelivery = false
      await withCheckedContinuation { deliveryGate = $0 }
    }
    if deliveryFails { throw AppFailure.timedOut }
  }
  func verify(_ files: [URL], endpoint: URL, executable: URL, pid: Int32, timeout: TimeInterval)
    async throws
  { onVerify?() }
}
