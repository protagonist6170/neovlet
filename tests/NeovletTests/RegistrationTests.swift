import Foundation
import Testing

@testable import Neovlet

@Suite @MainActor struct RegistrationTests {
  @Test func allocationFailureIsUnperformedAndDoesNotLeaveAnUnconfirmedCommit() async throws {
    let fixture = SessionFixture()
    fixture.store.allocationFails = true
    let session = fixture.session
    session.submit(.activate)
    session.submit(.activate)
    try await eventually { fixture.observer().reports.count == 2 }
    #expect(
      fixture.observer().reports.allSatisfy {
        if case .request(let report) = $0, case .notPerformed = report.result {
          true
        } else {
          false
        }
      })
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.creates == 0)
    #expect(session.requestTermination(.automatic) == .allow)
  }

  @Test func aGenerationAppearingDuringDependencyResolutionIsNotOverwritten() async throws {
    let fixture = SessionFixture()
    var resolution: CheckedContinuation<Dependencies, Never>?
    fixture.resolve = { await withCheckedContinuation { resolution = $0 } }
    let session = fixture.session
    session.submit(.activate)
    try await eventually { resolution != nil }
    let record = try fixture.store.allocate(using: fixture.dependencies)
    try fixture.store.save(record)
    resolution?.resume(returning: fixture.dependencies)
    try await eventually { fixture.lastStop() != nil }
    #expect(fixture.store.record == record)
    #expect(fixture.ghostty.creates == 0)
    #expect(fixture.lastStop()?.current == nil)
  }

  @Test(arguments: [DiskLoss.missing, .corrupt])
  func conflictOnlyIdentityProtectsALiveEditorAfterDiskLoss(_ loss: DiskLoss) async throws {
    let test = try RegistrationFixture()
    let observed = try await test.interruptCreationWithRegisteredEditor()
    let session = test.session
    #expect(try test.store.load() == observed)
    #expect(test.fixture.ghostty.creates == 0)

    // No baseline or candidate exists yet; the observed identity is held only by the conflict.
    switch loss {
    case .missing: try test.store.forget()
    case .corrupt: try Data("broken".utf8).write(to: test.registrationURL)
    case .unchanged: Issue.record("This test requires a missing or corrupt registration")
    }
    let contents = try? Data(contentsOf: test.registrationURL)
    let removals = test.faults.directoryRemovals
    let saves = test.faults.saves.count
    test.fixture.neovim.identificationFails = true
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: session) }
    #expect(test.observer.reports.last == .recovery(.refused(.editorStillRunning)))
    let termination = session.requestTermination(.automatic)
    #expect(termination == .cancel)
    guard termination == .cancel else { return }
    test.fixture.processProblem = AppFailure.message("process identity unavailable")
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: session) }
    guard case .recovery(.failed) = test.observer.reports.last else {
      Issue.record("Unknown process identity must preserve the registration evidence")
      return
    }
    #expect(session.requestTermination(.automatic) == .cancel)
    #expect((try? Data(contentsOf: test.registrationURL)) == contents)
    #expect(test.faults.directoryRemovals == removals)
    #expect(test.faults.saves.count == saves)
    #expect(test.fixture.ghostty.creates == 0)
    #expect(test.fixture.ghostty.focuses == 0)
    #expect(test.fixture.neovim.deliveries.isEmpty)

    // Readability returning is not verification. Keep the monitor check independent of read errors.
    if loss == .corrupt { try test.store.save(observed) }
    let monitorContents = try? Data(contentsOf: test.registrationURL)
    let monitorSaves = test.faults.saves.count
    test.fixture.processProblem = nil
    test.fixture.alive = false
    test.fixture.tick(session)
    #expect((try? Data(contentsOf: test.registrationURL)) == monitorContents)
    #expect(test.faults.directoryRemovals == removals)
    #expect(test.faults.saves.count == monitorSaves)
    #expect(test.fixture.ghostty.closedTerminals.isEmpty)
    let afterObservation = session.requestTermination(.automatic)
    #expect(afterObservation == .cancel)
    guard afterObservation == .cancel else { return }

    // Only explicit recovery can retire the retained, now-ended identity.
    try await test.fixture.forget(on: session)
    #expect(try test.store.load() == nil)
    #expect(test.faults.directoryRemovals == removals + 1)
    #expect(session.requestTermination(.automatic) == .allow)
  }

  @Test(arguments: [DiskLoss.missing, .corrupt], [Conflict.editor, .generation])
  func contradictoryConflictOnlyIdentitiesPreventCleanupAfterDiskLoss(
    _ loss: DiskLoss, _ conflict: Conflict
  ) async throws {
    let test = try RegistrationFixture()
    let first = try await test.interruptCreationWithRegisteredEditor()
    var second = first
    switch conflict {
    case .editor:
      second.editor = ProcessIdentity(pid: 20, startedSeconds: 201, startedMicroseconds: 0)
    case .generation:
      let allocated = try test.store.allocate(using: first.dependencies)
      second = Registration(
        id: allocated.id, endpoint: allocated.endpoint, dependencies: first.dependencies,
        phase: first.phase, ghostty: first.ghostty, terminalID: first.terminalID,
        editor: first.editor)
    default:
      Issue.record("This test requires editor or generation conflicts")
      return
    }
    try test.store.save(second)
    // Every recorded editor instance has ended; only the identity conflict should block cleanup.
    test.fixture.alive = false
    let session = test.session
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: session) }
    guard case .recovery(.failed) = test.observer.reports.last else {
      Issue.record("Conflicting records must not select a winner")
      return
    }
    #expect(try test.store.load() == second)
    switch loss {
    case .missing: try test.store.forget()
    case .corrupt: try Data("broken".utf8).write(to: test.registrationURL)
    case .unchanged:
      Issue.record("This test requires a missing or corrupt registration")
      return
    }
    let contents = try? Data(contentsOf: test.registrationURL)
    let removals = test.faults.directoryRemovals
    let saves = test.faults.saves.count
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: session) }
    guard case .recovery(.failed) = test.observer.reports.last else {
      Issue.record("Contradictory retained clues must still block cleanup after disk loss")
      return
    }
    test.fixture.tick(session)
    #expect((try? Data(contentsOf: test.registrationURL)) == contents)
    #expect(test.faults.directoryRemovals == removals)
    #expect(test.faults.saves.count == saves)
    #expect(test.fixture.ghostty.closedTerminals.isEmpty)
    #expect(test.fixture.ghostty.creates == 0)
    #expect(test.fixture.ghostty.focuses == 0)
    #expect(test.fixture.neovim.deliveries.isEmpty)
    #expect(session.requestTermination(.automatic) == .cancel)
  }

  @Test(arguments: [SessionStore.StorageStep.beforeReplacement, .afterReplacement])
  func preparingFailureStopsAllIntentWithoutCreating(_ point: SessionStore.StorageStep) async throws
  {
    let test = try RegistrationFixture()
    test.faults.fail = { operation, step in
      operation.saveStage == .preparing && step == point
    }
    let session = test.session
    let files = Session.Request.files([URL(fileURLWithPath: #filePath)])
    session.submit(files)
    session.submit(.activate)
    try await eventually { test.fixture.lastStop(session) != nil }
    let stopped = try #require(test.fixture.lastStop(session))
    #expect(stopped.current == nil)
    #expect(stopped.notProcessed == [files, .activate])
    #expect(try test.store.load()?.phase == (point == .afterReplacement ? .preparing : nil))
    #expect(test.fixture.ghostty.creates == 0)
    #expect(test.fixture.neovim.deliveries.isEmpty)
    #expect(session.requestTermination(.automatic) == .cancel)
    test.fixture.tick(session)
    #expect(test.faults.failures == 1)
    #expect(test.faults.saves.count == 1)
    // Only a new explicit intent may confirm retirement and proceed; old files are not replayed.
    test.faults.fail = nil
    #expect(try await test.perform(.activate) == .focused)
    #expect(test.fixture.ghostty.creates == 1)
    #expect(test.fixture.neovim.deliveries.isEmpty)
  }

  @Test func startingDirectorySyncFailureDoesNotAuthorizeCreationOnReadback() async throws {
    let test = try RegistrationFixture()
    test.faults.fail = { operation, step in
      operation.saveStage == .starting && step == .beforeDirectorySync
    }
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(try test.store.load()?.phase == .starting)
    #expect(test.fixture.ghostty.creates == 0)
    let saved = test.faults.saves.count
    test.fixture.neovim.identificationFails = true
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(test.faults.saves.count == saved)
    #expect(test.fixture.ghostty.focuses == 0)
    #expect(test.fixture.ghostty.creates == 0)
    #expect(test.faults.failures == 1)
    #expect(test.session.requestTermination(.automatic) == .cancel)
  }

  @Test func terminalReplyFailureRetainsItsIdentityAndNeverReleasesTheEditor() async throws {
    let test = try RegistrationFixture()
    var released = false
    test.fixture.ghostty.onCreate = { released = true }
    test.faults.fail = { operation, step in
      operation.saveStage == .terminalCreated && step == .beforeReplacement
    }
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(try test.store.load()?.terminalID == nil)
    #expect(!released)
    #expect(test.fixture.ghostty.creates == 1)
    #expect(test.fixture.lastStop(test.session)?.current?.operation == .creation)
    // The ID absent from disk is still used to check the waiting terminal on explicit recovery.
    test.fixture.neovim.identificationFails = true
    test.fixture.ghostty.terminalFinished = false
    var inspected = false
    test.fixture.ghostty.onClose = { inspected = true }
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(inspected)
    #expect(test.faults.failures == 1)
    #expect(test.fixture.ghostty.creates == 1)
    #expect(test.fixture.ghostty.closedTerminals.isEmpty)
  }

  enum DiskLoss: CaseIterable { case unchanged, missing, corrupt }

  @Test(arguments: DiskLoss.allCases)
  func failedEditorCommitProtectsTheObservedInstanceEvenWithoutRPC(_ loss: DiskLoss) async throws {
    let test = try RegistrationFixture()
    test.faults.fail = { operation, step in
      operation.saveStage == .editorIdentified && step == .beforeReplacement
    }
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(try test.store.load()?.editor == nil)
    switch loss {
    case .unchanged: break
    case .missing: try test.store.forget()
    case .corrupt: try Data("broken".utf8).write(to: test.registrationURL)
    }
    test.fixture.neovim.identificationFails = true
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: test.session) }
    #expect(test.observer.reports.last == .recovery(.refused(.editorStillRunning)))
    test.fixture.processProblem = AppFailure.message("process identity unavailable")
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: test.session) }
    #expect(
      test.observer.reports.contains { if case .recovery(.failed) = $0 { true } else { false } })
    #expect(test.fixture.ghostty.creates == 1)
    #expect(test.faults.failures == 1)
    #expect(test.session.requestTermination(.automatic) == .cancel)
    test.fixture.processProblem = nil
    test.fixture.alive = false
    try await test.fixture.forget(on: test.session)
    #expect(try test.store.load() == nil)
    #expect(test.session.requestTermination(.automatic) == .allow)
  }

  @Test func anEditorObservationSurvivesAReadFailureBeforeItsCommit() async throws {
    let test = try RegistrationFixture()
    test.fixture.neovim.onIdentify = {
      try? Data("unreadable after RPC".utf8).write(to: test.registrationURL)
    }
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(throws: AppFailure.self) { try test.store.load() }
    test.fixture.neovim.identificationFails = true
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: test.session) }
    #expect(test.observer.reports.last == .recovery(.refused(.editorStillRunning)))
    #expect(test.fixture.ghostty.creates == 1)
    #expect(test.fixture.ghostty.closedTerminals.isEmpty)
  }

  @Test func readySyncFailureEscapesPollingBeforeReceiptFocusOrCleanup() async throws {
    let test = try RegistrationFixture()
    test.faults.fail = { operation, step in
      operation.saveStage == .associationVerified && step == .beforeFileSync
    }
    var receipts = 0
    test.fixture.neovim.onVerify = { receipts += 1 }
    await #expect(throws: ReportFailure.self) {
      try await test.perform(.files([URL(fileURLWithPath: #filePath)]))
    }
    #expect(try test.store.load()?.phase == .ready)
    #expect(receipts == 0)
    #expect(test.fixture.ghostty.focuses == 0)
    #expect(test.fixture.neovim.deliveries.isEmpty)
    let saves = test.faults.saves.count
    test.fixture.alive = false
    test.fixture.tick(test.session)
    #expect(try test.store.load() != nil)
    #expect(test.fixture.ghostty.closedTerminals.isEmpty)
    #expect(test.faults.saves.count == saves)
    #expect(test.faults.failures == 1)
    #expect(test.session.requestTermination(.automatic) == .cancel)
    try await test.fixture.forget(on: test.session)
    #expect(try test.store.load() == nil)
  }

  @Test func reusedReadySnapshotsAreSelectedByPlatformFactsRatherThanWriteOrdinals() async throws {
    let test = try RegistrationFixture()
    _ = try await test.perform(.activate)
    let committed = try #require(try test.store.load())
    // Both saves on reuse have identical ready payloads. Arm only after terminal verification.
    test.fixture.ghostty.onTerminal = {
      test.faults.fail = { operation, step in
        operation.saveStage == .associationVerified && step == .beforeDirectorySync
      }
    }
    let start = test.faults.saves.count
    await #expect(throws: ReportFailure.self) {
      try await test.perform(.files([URL(fileURLWithPath: #filePath)]))
    }
    #expect(Array(test.faults.saves.dropFirst(start)) == [committed, committed])
    #expect(test.fixture.neovim.deliveries.isEmpty)
    #expect(test.fixture.ghostty.focuses == 1)
    #expect(test.faults.failures == 1)
    test.fixture.tick(test.session)
    #expect(test.faults.saves.count == start + 2)
    test.faults.fail = nil
    test.fixture.ghostty.onTerminal = nil
    #expect(try await test.perform(.activate) == .focused)
    #expect(test.fixture.ghostty.creates == 1)
  }

  @Test func compatibleGapsAreReverifiedAndTheCommittedBaselineIsNotDowngraded() async throws {
    let test = try RegistrationFixture()
    _ = try await test.perform(.activate)
    let baseline = try #require(try test.store.load())
    var partial = baseline
    partial.editor = nil
    partial.terminalID = nil
    partial.phase = .starting
    try test.store.save(partial)
    let start = test.faults.saves.count
    test.fixture.neovim.onIdentify = {
      test.faults.fail = { _, step in step == .beforeReplacement }
    }
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(test.faults.saves.last?.phase == .ready)
    #expect(test.faults.saves.count == start + 1)
    #expect(try test.store.load() == partial)
    test.fixture.neovim.identificationFails = true
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: test.session) }
    #expect(test.observer.reports.last == .recovery(.refused(.editorStillRunning)))
    test.faults.fail = nil
    test.fixture.neovim.onIdentify = nil
    test.fixture.neovim.identificationFails = false
    _ = try await test.perform(.activate)
    #expect(try test.store.load() == baseline)
    #expect(test.fixture.ghostty.creates == 1)
  }

  enum Conflict: CaseIterable { case editor, terminal, ghostty, generation, dependencies }

  @Test(arguments: Conflict.allCases)
  func incompatibleEvidenceCannotBeMergedOverwrittenOrDiscarded(_ kind: Conflict) async throws {
    let test = try RegistrationFixture()
    _ = try await test.perform(.activate)
    var other = try #require(try test.store.load())
    switch kind {
    case .editor:
      other.editor = ProcessIdentity(pid: 20, startedSeconds: 201, startedMicroseconds: 1)
    case .terminal: other.terminalID = "another-terminal"
    case .ghostty:
      other.ghostty = ProcessIdentity(pid: 10, startedSeconds: 101, startedMicroseconds: 0)
    case .generation: other = try test.store.allocate(using: test.fixture.dependencies)
    case .dependencies:
      other = Registration(
        id: other.id, endpoint: other.endpoint,
        dependencies: Dependencies(
          ghostty: other.dependencies.ghostty, neovim: URL(fileURLWithPath: "/different/nvim"),
          ghosttyIdentifier: other.dependencies.ghosttyIdentifier),
        phase: other.phase, ghostty: other.ghostty, terminalID: other.terminalID,
        editor: other.editor)
    }
    try test.store.save(other)
    let saves = test.faults.saves.count
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(try test.store.load() == other)
    #expect(test.faults.saves.count == saves)
    #expect(test.fixture.ghostty.focuses == 1)
    test.fixture.alive = false
    await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: test.session) }
    #expect(try test.store.load() == other)
    #expect(test.fixture.ghostty.closedTerminals.isEmpty)
    #expect(test.fixture.ghostty.creates == 1)
  }

  @Test(arguments: [false, true])
  func unlinkNeedsDirectoryConfirmationAndIsNotRetriedByTheMonitor(explicit: Bool) async throws {
    let test = try RegistrationFixture()
    _ = try await test.perform(.activate)
    test.fixture.alive = false
    test.faults.fail = { operation, step in
      guard step == .beforeDirectorySync else { return false }
      return switch operation {
      case .clear: !explicit
      case .forget: explicit
      case .save: false
      }
    }
    if explicit {
      await #expect(throws: AppFailure.self) { try await test.fixture.forget(on: test.session) }
    } else {
      test.fixture.tick(test.session)
    }
    #expect(try test.store.load() == nil)
    #expect(test.session.requestTermination(.automatic) == .cancel)
    #expect(test.faults.failures == 1)
    let removals = test.faults.directoryRemovals
    test.fixture.tick(test.session)
    #expect(test.faults.directoryRemovals == removals)
    test.faults.fail = nil
    // Even an already absent record needs a new explicit operation and successful directory sync.
    if explicit {
      try await test.fixture.forget(on: test.session)
      #expect(test.session.requestTermination(.automatic) == .allow)
    } else {
      test.fixture.ghostty.onCreate = { test.fixture.alive = true }
      #expect(try await test.perform(.activate) == .focused)
      #expect(test.fixture.ghostty.creates == 2)
    }
    #expect(test.faults.directoryRemovals == removals + 1)
  }

  @Test(arguments: [false, true])
  func realUnlinkFailureLeavesAbsenceUnconfirmedUntilDirectorySync(explicit: Bool) throws {
    let test = try RegistrationFixture()
    let record = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(record)
    test.faults.fail = { _, step in step == .afterUnlink }
    #expect(throws: AppFailure.self) {
      if explicit { try test.store.forget() } else { try test.store.clear(record.id) }
    }
    #expect(try test.store.load() == nil)
    #expect(test.faults.directoryRemovals == 0)
    test.faults.fail = nil
    if explicit { try test.store.forget() } else { try test.store.clear(record.id) }
    #expect(test.faults.directoryRemovals == 1)
  }

  @Test func generationChangedDuringRPCVerificationIsNeverDeleted() async throws {
    let test = try RegistrationFixture()
    let old = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(old)
    _ = test.session
    test.fixture.neovim.pauseIdentification = true
    test.session.forgetAfterUserConfirmation()
    try await eventually { test.fixture.neovim.identificationGate != nil }
    let replacement = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(replacement)
    test.fixture.neovim.identificationGate?.resume(throwing: AppFailure.timedOut)
    try await eventually {
      test.observer.reports.contains { if case .recovery(.failed) = $0 { true } else { false } }
    }
    #expect(try test.store.load() == replacement)
    #expect(test.faults.directoryRemovals == 0)
    #expect(test.session.requestTermination(.automatic) == .cancel)
  }

  @Test func corruptRecordConfirmationDoesNotCoverANewReadableGeneration() async throws {
    let test = try RegistrationFixture()
    let old = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(old)
    _ = test.session
    try Data("broken".utf8).write(to: test.registrationURL)
    test.fixture.neovim.pauseIdentification = true
    test.session.forgetAfterUserConfirmation()
    try await eventually { test.fixture.neovim.identificationGate != nil }
    let replacement = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(replacement)
    test.fixture.neovim.identificationGate?.resume(throwing: AppFailure.timedOut)
    try await eventually {
      test.observer.reports.contains { if case .recovery(.failed) = $0 { true } else { false } }
    }
    #expect(try test.store.load() == replacement)
    #expect(test.faults.directoryRemovals == 0)
  }

  @Test func aTerminalIDWithoutItsGhosttyInstanceCannotProveAnInterruptedStartupEnded() async throws
  {
    let test = try RegistrationFixture()
    var record = try test.store.allocate(using: test.fixture.dependencies)
    record.phase = .starting
    record.terminalID = "owned"
    try test.store.save(record)
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(try test.store.load() == record)
    #expect(test.faults.directoryRemovals == 0)
    #expect(test.fixture.ghostty.creates == 0)
    test.fixture.neovim.identificationFails = true
    try await test.fixture.forget(on: test.session)
    #expect(try test.store.load() == nil)
  }

  @Test func aPreparingBaselineCannotHideALaterCreationPhase() async throws {
    let test = try RegistrationFixture()
    var record = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(record)
    _ = test.session
    // Missing identity fields are allowed in v1 partial snapshots. Starting is still a clue.
    record.phase = .starting
    try test.store.save(record)
    await #expect(throws: ReportFailure.self) { try await test.perform(.activate) }
    #expect(try test.store.load() == record)
    #expect(test.fixture.ghostty.creates == 0)
    #expect(test.faults.directoryRemovals == 0)
  }

  @Test func unreadableRecordWithoutIdentityCluesCanStillBeExplicitlyDiscarded() async throws {
    let test = try RegistrationFixture()
    try Data("broken".utf8).write(to: test.registrationURL)
    let session = test.session
    try await eventually { test.fixture.lastStop(session) != nil }
    #expect(session.requestTermination(.automatic) == .cancel)
    try await test.fixture.forget(on: session)
    #expect(try test.store.load() == nil)
    #expect(test.faults.directoryRemovals == 1)
    #expect(session.requestTermination(.automatic) == .allow)
  }

  @Test func restartedPreparingRegistrationIsRetiredOnTheFirstExplicitRequest() async throws {
    let test = try RegistrationFixture()
    let abandoned = try test.store.allocate(using: test.fixture.dependencies)
    try test.store.save(abandoned)
    #expect(try await test.perform(.activate) == .focused)
    #expect(try test.store.load()?.id != abandoned.id)
    #expect(test.fixture.ghostty.creates == 1)
    #expect(test.faults.directoryRemovals == 1)
  }
}

/// Real atomic replacement/unlink in an isolated namespace, with controlled platform adapters.
@MainActor private final class RegistrationFixture {
  let fixture = SessionFixture()
  let faults = RegistrationFaults()
  let store: SessionStore
  let root: URL
  let socketDirectory: URL
  var registrationURL: URL { store.directory.appendingPathComponent("session.json") }
  lazy var session = fixture.makeSession(store: store)
  var observer: SessionObserver { fixture.observer(session) }

  init() throws {
    root = try testDirectory()
    let faults = faults
    store = try SessionStore(namespace: UUID().uuidString, root: root) {
      try faults.check($0, $1)
    }
    socketDirectory = store.socketDirectory
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: socketDirectory)
  }

  @discardableResult
  func perform(_ request: Session.Request) async throws -> Session.Outcome {
    try await fixture.perform(on: session, request, using: fixture.dependencies)
  }

  /// An unexpected disk record interrupts preparation before Session has a baseline or candidate.
  func interruptCreationWithRegisteredEditor() async throws -> Registration {
    var resolution: CheckedContinuation<Dependencies, Never>?
    fixture.resolve = { await withCheckedContinuation { resolution = $0 } }
    session.submit(.activate)
    try await eventually { resolution != nil }
    let allocated = try store.allocate(using: fixture.dependencies)
    let observed = Registration(
      id: allocated.id, endpoint: allocated.endpoint, dependencies: allocated.dependencies,
      phase: .ready, ghostty: fixture.application, terminalID: "owned", editor: fixture.editor)
    try store.save(observed)
    resolution?.resume(returning: fixture.dependencies)
    try await eventually { self.fixture.lastStop(self.session) != nil }
    return observed
  }
}

private enum SaveStage {
  case preparing, starting, terminalCreated, editorIdentified, associationVerified
}

extension SessionStore.StorageOperation {
  fileprivate var saveStage: SaveStage? {
    guard case .save(let record) = self else { return nil }
    switch record.phase {
    case .preparing: return .preparing
    case .ready: return .associationVerified
    case .starting:
      if record.editor != nil { return .editorIdentified }
      return record.terminalID == nil ? .starting : .terminalCreated
    }
  }
}

@MainActor private final class RegistrationFaults {
  var fail: ((SessionStore.StorageOperation, SessionStore.StorageStep) -> Bool)?
  var saves: [Registration] = []
  var failures = 0
  var directoryRemovals = 0

  func check(_ operation: SessionStore.StorageOperation, _ step: SessionStore.StorageStep) throws {
    if case .save(let record) = operation, step == .beforeReplacement { saves.append(record) }
    if step == .beforeDirectorySync, operation.saveStage == nil { directoryRemovals += 1 }
    if fail?(operation, step) == true {
      failures += 1
      throw AppFailure.message("injected storage failure")
    }
  }
}
