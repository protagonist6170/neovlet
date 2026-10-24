import Foundation
import Testing

@testable import Neovlet

@Suite @MainActor struct SessionRequestTests {
  @Test func configurationWaitRetainsIntentOrderAndResolvesOnlyForCreation() async throws {
    let fixture = SessionFixture()
    fixture.resolve = { throw AppFailure.message("Choose dependencies") }
    let session = fixture.session
    let observer = fixture.observer()
    let first = URL(fileURLWithPath: #filePath)
    let second = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("SessionTests.swift")
    session.submit(.activate)
    try await eventually { observer.settingsProblems.count == 1 }
    session.settingsOpened()
    session.submit(.files([first]))
    session.submit(.files([second]))
    #expect(fixture.resolutions == 1)
    #expect(fixture.ghostty.creates == 0)
    fixture.resolve = nil
    session.settingsClosed(.saved)
    try await eventually { observer.reports.count == 3 }
    #expect(
      observer.reports == [
        .request(.init(request: .activate, result: .completed(.focused))),
        .request(.init(request: .files([first]), result: .completed(.opened))),
        .request(.init(request: .files([second]), result: .completed(.opened))),
      ])
    #expect(fixture.neovim.deliveries == [[first], [second]])
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.resolutions == 2)
  }

  @Test func filesAreRevalidatedAfterSettingsAndOnlyTheInvalidBatchFails() async throws {
    let fixture = SessionFixture()
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disappearing = directory.appendingPathComponent("gone.txt")
    try Data().write(to: disappearing)
    fixture.resolve = { throw AppFailure.message("Choose dependencies") }
    let session = fixture.session
    let observer = fixture.observer()
    session.submit(.files([disappearing]))
    try await eventually { observer.settingsProblems.count == 1 }
    session.settingsOpened()
    session.submit(.activate)
    try FileManager.default.removeItem(at: disappearing)
    fixture.resolve = nil
    session.settingsClosed(.saved)
    try await eventually { observer.reports.count == 2 }
    guard case .request(let first) = observer.reports[0],
      case .notPerformed = first.result
    else {
      Issue.record("The vanished file must be rejected without opening it")
      return
    }
    #expect(first.request == .files([disappearing]))
    #expect(
      observer.reports[1] == .request(.init(request: .activate, result: .completed(.focused))))
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.ghostty.launchCommand?.contains(disappearing.path) == false)
  }

  @Test(arguments: [false, true])
  func cancelledPreparationCannotReturnWithOldFilesOrErrors(fails: Bool) async throws {
    let fixture = SessionFixture()
    var gate: CheckedContinuation<Dependencies, any Error>?
    fixture.resolve = { try await withCheckedThrowingContinuation { gate = $0 } }
    let session = fixture.session
    let observer = fixture.observer()
    let old = Session.Request.files([URL(fileURLWithPath: #filePath)])
    session.submit(old)
    try await eventually { gate != nil }
    session.settingsOpened()
    session.submit(.activate)
    session.settingsClosed(.cancelled)
    // A later explicit request is independent of the abandoned preparation.
    fixture.resolve = nil
    let fresh = Session.Request.files([URL(fileURLWithPath: #filePath)])
    session.submit(fresh)
    if fails {
      gate?.resume(throwing: AppFailure.message("obsolete error"))
    } else {
      gate?.resume(returning: fixture.dependencies)
    }
    try await eventually { observer.reports.count == 2 }
    #expect(observer.reports[0] == .cancelled([old, .activate], reason: .settingsCancelled))
    #expect(observer.reports[1] == .request(.init(request: fresh, result: .completed(.opened))))
    #expect(observer.settingsProblems.isEmpty)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.neovim.deliveries.isEmpty)
  }

  @Test func settingsCancellationLeavesAnActiveCreationAndItsSnapshotIntact() async throws {
    let fixture = SessionFixture()
    let session = fixture.session
    let observer = fixture.observer()
    fixture.ghostty.pauseCreation = true
    session.submit(.activate)
    try await eventually { fixture.ghostty.creationGate != nil }
    let oldDependencies = fixture.dependencies
    fixture.selectedDependencies = Dependencies(
      ghostty: URL(fileURLWithPath: "/new/Ghostty.app"), neovim: URL(fileURLWithPath: "/new/nvim"),
      ghosttyIdentifier: "new.ghostty")
    session.settingsOpened()
    let pending = Session.Request.files([URL(fileURLWithPath: #filePath)])
    session.submit(pending)
    session.submit(.activate)
    session.settingsClosed(.cancelled)
    fixture.ghostty.creationGate?.resume()
    try await eventually { observer.reports.count == 2 }
    #expect(observer.reports[0] == .cancelled([pending, .activate], reason: .settingsCancelled))
    #expect(
      observer.reports[1] == .request(.init(request: .activate, result: .completed(.focused))))
    #expect(fixture.store.record?.dependencies == oldDependencies)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.neovim.deliveries.isEmpty)
  }

  @Test func settingsSaveDoesNotRebindAnActiveCreationOrItsFollowingRequests() async throws {
    let fixture = SessionFixture()
    fixture.ghostty.pauseCreation = true
    let session = fixture.session
    let observer = fixture.observer()
    session.submit(.activate)
    try await eventually { fixture.ghostty.creationGate != nil }
    session.settingsOpened()
    session.submit(.files([URL(fileURLWithPath: #filePath)]))
    fixture.selectedDependencies = Dependencies(
      ghostty: URL(fileURLWithPath: "/new/Ghostty.app"), neovim: URL(fileURLWithPath: "/new/nvim"),
      ghosttyIdentifier: "new.ghostty")
    fixture.ghostty.creationGate?.resume()
    try await eventually { observer.reports.count == 1 }
    #expect(fixture.neovim.deliveries.isEmpty)
    session.settingsClosed(.saved)
    try await eventually { observer.reports.count == 2 }
    #expect(fixture.ghostty.observedDependencies.allSatisfy { $0 == fixture.dependencies })
    #expect(fixture.resolutions == 1)
  }

  @Test func reportsBlockTheNextRequestAndAnOldReceiptCannotReleaseANewOne() async throws {
    let fixture = SessionFixture()
    let session = fixture.session
    let observer = fixture.observer()
    observer.acknowledge = false
    let invalid = Session.Request.files([])
    session.submit(invalid)
    session.submit(invalid)
    session.submit(.activate)
    try await eventually { observer.reports.count == 2 }
    let first = observer.presentations[0]
    let second = observer.presentations[1]
    session.presentationClosed(first)
    session.presentationClosed(first)
    #expect(fixture.ghostty.creates == 0)
    #expect(session.requestTermination(.automatic) == .cancel)
    session.presentationClosed(second)
    try await eventually { observer.reports.count == 3 }
    #expect(fixture.ghostty.creates == 1)
    session.presentationClosed(observer.presentations[2])
  }

  @Test func unconfirmedDeliveryStopsTheWholeQueueInOneReport() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let session = fixture.session
    let observer = fixture.observer()
    let start = observer.reports.count
    let active = Session.Request.files([URL(fileURLWithPath: #filePath)])
    fixture.neovim.pauseDelivery = true
    fixture.neovim.deliveryFails = true
    session.submit(active)
    try await eventually { fixture.neovim.deliveryGate != nil }
    session.submit(.activate)
    session.submit(active)
    fixture.neovim.deliveryGate?.resume()
    try await eventually { observer.reports.count == start + 1 }
    let stopped = try #require(fixture.lastStop())
    #expect(stopped.current == .init(request: active, operation: .delivery))
    #expect(stopped.notProcessed == [.activate, active])
    #expect(fixture.neovim.deliveries.count == 1)
    #expect(fixture.ghostty.creates == 1)
  }

  @Test func deniedAuthorizationNeverLabelsUnsentFilesAsPossiblyDelivered() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    fixture.ghostty.authorizationFailure = GhosttyFailure(code: -1743, detail: "denied")
    let session = fixture.session
    let request = Session.Request.files([URL(fileURLWithPath: #filePath)])
    session.submit(request)
    session.submit(.activate)
    try await eventually { fixture.lastStop() != nil }
    let stopped = try #require(fixture.lastStop())
    #expect(stopped.current == nil)
    #expect(stopped.notProcessed == [request, .activate])
    #expect(fixture.neovim.deliveries.isEmpty)
    #expect(fixture.store.record != nil)
  }

  @Test(arguments: [false, true])
  func recoverySerializesOpensAndReleasesTheSlotOnEitherResult(forgetFails: Bool) async throws {
    let fixture = SessionFixture()
    let old = Registration(
      id: UUID(), endpoint: URL(fileURLWithPath: "/private/tmp/test.sock"),
      dependencies: fixture.dependencies, phase: .starting, ghostty: fixture.application)
    fixture.store.record = old
    fixture.store.forgetFails = forgetFails
    fixture.neovim.pauseIdentification = true
    let session = fixture.session
    let observer = fixture.observer()
    let changed = Dependencies(
      ghostty: URL(fileURLWithPath: "/new/Ghostty.app"), neovim: URL(fileURLWithPath: "/new/nvim"),
      ghosttyIdentifier: "new.ghostty")
    fixture.selectedDependencies = changed
    session.forgetAfterUserConfirmation()
    try await eventually { fixture.neovim.identificationGate != nil }
    session.forgetAfterUserConfirmation()
    #expect(session.requestTermination(.userRequested) == .cancel)
    session.submit(.files([URL(fileURLWithPath: #filePath)]))
    fixture.tick()
    #expect(fixture.store.record == old)
    #expect(fixture.resolutions == 0)
    fixture.neovim.identificationGate?.resume(throwing: AppFailure.timedOut)
    try await eventually {
      observer.reports.contains(
        .request(
          .init(
            request: .files([URL(fileURLWithPath: #filePath)]), result: .completed(.opened))))
    }
    #expect(observer.reports.contains(.recovery(.refused(.busy))))
    #expect(observer.reports.contains(.quitRefused))
    if forgetFails {
      #expect(observer.reports.contains { if case .recovery(.failed) = $0 { true } else { false } })
    } else {
      #expect(observer.reports.contains(.recovery(.forgotten)))
    }
    if forgetFails {
      // Failed clearing leaves the old registration; the queued request may recover it.
      #expect(fixture.store.record?.id == old.id)
      #expect(fixture.store.record?.dependencies == fixture.dependencies)
      #expect(fixture.ghostty.creates == 0)
      #expect(fixture.resolutions == 0)
    } else {
      #expect(fixture.store.record?.id != old.id)
      #expect(fixture.store.record?.dependencies == changed)
      #expect(fixture.ghostty.creates == 1)
      #expect(fixture.resolutions == 1)
    }
  }

  @Test func automaticExitUsesCurrentFactsAndCommitsTerminationOnce() async throws {
    let fixture = SessionFixture()
    let session = fixture.makeSession(ready: false)
    let observer = fixture.observer(session)
    #expect(session.requestTermination(.automatic) == .cancel)
    let presentation = session.presentationOpened()
    session.applicationReady()
    #expect(session.requestTermination(.automatic) == .cancel)
    #expect(fixture.ghostty.creates == 0)
    session.presentationClosed(presentation)
    try await eventually { observer.terminationSuggestions == 1 }
    session.settingsOpened()
    session.submit(.activate)
    #expect(session.requestTermination(.automatic) == .cancel)
    session.settingsClosed(.cancelled)
    try await eventually { observer.terminationSuggestions == 2 }
    #expect(session.requestTermination(.automatic) == .allow)
    #expect(session.requestTermination(.userRequested) == .allow)
    #expect(observer.monitorCancelled)
    session.submit(.activate)
    fixture.tick(session)
    #expect(fixture.ghostty.creates == 0)
  }

  @Test func explicitQuitDuringSettingsCancelsPendingIntentWithoutCreating() async throws {
    let fixture = SessionFixture()
    fixture.resolve = { throw AppFailure.message("Choose dependencies") }
    let session = fixture.session
    let observer = fixture.observer()
    session.submit(.activate)
    try await eventually { observer.settingsProblems.count == 1 }
    session.settingsOpened()
    #expect(session.requestTermination(.userRequested) == .allow)
    session.settingsClosed(.saved)
    try await eventually { observer.reports.count == 1 }
    #expect(observer.reports == [.cancelled([.activate], reason: .managerQuit)])
    #expect(fixture.ghostty.creates == 0)
    #expect(observer.monitorCancelled)
  }

  @Test func explicitQuitPreservesTheRegisteredEditor() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let record = try #require(fixture.store.record)
    #expect(fixture.session.requestTermination(.userRequested) == .allow)
    #expect(fixture.store.record == record)
    #expect(fixture.ghostty.closedTerminals.isEmpty)
    fixture.session.submit(.activate)
    #expect(fixture.ghostty.creates == 1)
  }

  enum BusyStage: CaseIterable { case resolving, authorizing, creating }

  @Test(arguments: BusyStage.allCases)
  func explicitQuitIsRefusedWhileAnOperationIsActive(_ stage: BusyStage) async throws {
    let fixture = SessionFixture()
    var resolution: CheckedContinuation<Dependencies, any Error>?
    switch stage {
    case .resolving:
      fixture.resolve = { try await withCheckedThrowingContinuation { resolution = $0 } }
    case .authorizing: fixture.ghostty.pauseAuthorization = true
    case .creating: fixture.ghostty.pauseCreation = true
    }
    let session = fixture.session
    let observer = fixture.observer()
    session.submit(.activate)
    try await eventually {
      switch stage {
      case .resolving: resolution != nil
      case .authorizing: fixture.ghostty.authorizationGate != nil
      case .creating: fixture.ghostty.creationGate != nil
      }
    }
    #expect(session.requestTermination(.userRequested) == .cancel)
    resolution?.resume(returning: fixture.dependencies)
    fixture.ghostty.authorizationGate?.resume()
    fixture.ghostty.creationGate?.resume()
    try await eventually { observer.reports.count == 2 }
    #expect(observer.reports.contains(.quitRefused))
    #expect(
      observer.reports.contains(.request(.init(request: .activate, result: .completed(.focused)))))
    #expect(!observer.monitorCancelled)
  }

  @Test func unreadableRegistrationPreventsAutomaticExitAndSilentCreation() async throws {
    let fixture = SessionFixture()
    fixture.store.loadFails = true
    let session = fixture.session
    try await eventually { fixture.lastStop() != nil }
    #expect(session.requestTermination(.automatic) == .cancel)
    session.submit(.activate)
    try await eventually { fixture.observer().reports.count == 2 }
    #expect(fixture.lastStop()?.notProcessed == [.activate])
    #expect(fixture.ghostty.creates == 0)
  }

  @Test func monitorFinishesAnEndedSessionBeforeSuggestingExit() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    fixture.alive = false
    fixture.tick()
    try await eventually { fixture.observer().terminationSuggestions > 0 }
    #expect(fixture.store.record == nil)
    #expect(fixture.ghostty.closedTerminals == ["owned"])
    #expect(fixture.session.requestTermination(.automatic) == .allow)
  }

  @Test func monitorKeepsItsOperationSlotAcrossReentrantNativeCallbacks() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let oldID = fixture.store.record?.id
    let session = fixture.session
    fixture.alive = false
    fixture.ghostty.onClose = {
      fixture.ghostty.onClose = nil
      // A synchronous platform call may pump AppKit's event loop, including another timer tick.
      fixture.tick()
      #expect(session.requestTermination(.userRequested) == .cancel)
      session.submit(.activate)
    }
    fixture.tick()
    fixture.alive = true
    try await eventually { fixture.ghostty.creates == 2 }
    #expect(fixture.ghostty.closedTerminals == ["owned"])
    try await eventually { fixture.store.record?.phase == .ready }
    #expect(fixture.store.record?.id != oldID)
  }

  @Test func unknownProcessObservationPreservesRegistrationAndUnsentRequests() async throws {
    let fixture = SessionFixture()
    _ = try await fixture.perform(.activate, using: fixture.dependencies)
    let record = fixture.store.record
    fixture.processProblem = AppFailure.message("process identity unavailable")
    fixture.tick()
    #expect(fixture.store.record == record)
    #expect(fixture.ghostty.closedTerminals.isEmpty)
    let request = Session.Request.files([URL(fileURLWithPath: #filePath)])
    fixture.session.submit(request)
    try await eventually { fixture.lastStop() != nil }
    #expect(fixture.lastStop()?.current == nil)
    #expect(fixture.lastStop()?.notProcessed == [request])
    #expect(fixture.store.record == record)
    #expect(fixture.session.requestTermination(.automatic) == .cancel)
  }

  @Test func callbacksCanSubmitAndEditSettingsWithoutNestedNotificationDelivery() async throws {
    let fixture = SessionFixture()
    let session = fixture.session
    let observer = fixture.observer()
    var callbackDepth = 0
    var maxDepth = 0
    observer.onEvent = { event in
      callbackDepth += 1
      maxDepth = max(maxDepth, callbackDepth)
      defer { callbackDepth -= 1 }
      if case .report(.request(let report), _) = event, report.request == .activate {
        session.settingsOpened()
        session.submit(.files([]))
        session.submit(.files([URL(fileURLWithPath: #filePath)]))
        session.settingsClosed(.saved)
      }
    }
    session.submit(.activate)
    try await eventually { observer.reports.count == 3 }
    #expect(maxDepth == 1)
    #expect(fixture.ghostty.creates == 1)
    #expect(fixture.neovim.deliveries == [[URL(fileURLWithPath: #filePath)]])
  }
}
