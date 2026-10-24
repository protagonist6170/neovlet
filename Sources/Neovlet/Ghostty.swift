import AppKit
import CoreServices
import Darwin
import Foundation

struct GhosttyFailure: Error, LocalizedError, Sendable {
  let code: Int32?
  let detail: String

  var errorDescription: String? {
    switch code {
    case Int32(errAEEventNotPermitted):
      "未获准控制 Ghostty（AppleEvent -1743）。请在“系统设置 → 隐私与安全性 → 自动化”中允许此应用控制 Ghostty，然后重新打开文件。"
    case Int32(errAEEventWouldRequireUserConsent):
      "控制 Ghostty 尚需授权（AppleEvent -1744）。请重新打开文件并完成系统授权。"
    case Int32(errAETimeout):
      "Ghostty 未在操作时限内回复（AppleEvent -1712）；操作结果尚未确认。"
    default:
      "Ghostty 操作失败\(code.map { "（AppleEvent \($0)）" } ?? "")：\(detail)"
    }
  }
}

struct OwnedTerminal: Equatable, Sendable {
  let id: String
  let pid: Int32
  let tty: String

  func containsClient(on devices: [dev_t]) throws -> Bool {
    var info = stat()
    guard tty.hasPrefix("/dev/"), stat(tty, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else {
      throw AppFailure.message("Ghostty 专用终端的 TTY 设备无法核验。")
    }
    return devices.contains(info.st_rdev)
  }
}

@MainActor protocol GhosttyAccess {
  func prepare(_ dependencies: Dependencies, deadline: TimeInterval) async throws -> ProcessIdentity
  func authorize(_ dependencies: Dependencies) async throws
  func create(
    _ dependencies: Dependencies, command: String, directory: URL, timeout: TimeInterval,
    onCreated: (OwnedTerminal) throws -> Void
  )
    async throws
    -> OwnedTerminal
  func terminal(
    _ dependencies: Dependencies, id: String?, matching pids: [Int32], timeout: TimeInterval
  ) async throws -> OwnedTerminal
  func focus(_ dependencies: Dependencies, terminalID: String, timeout: TimeInterval) async throws
  func closeFinished(_ dependencies: Dependencies, terminalID: String) throws -> Bool
}

/// The only code that knows the script's handler names and descriptor layout.
@MainActor final class Ghostty: GhosttyAccess {
  private let script: NSAppleScript

  init(scriptURL: URL) throws {
    var error: NSDictionary?
    guard let script = NSAppleScript(contentsOf: scriptURL, error: &error) else {
      throw AppFailure.message("Ghostty adapter 资源无法加载：\(error?.description ?? "未知错误")")
    }
    self.script = script
    guard try call("adapterversion", []).int32Value == 1 else {
      throw AppFailure.message("Ghostty adapter 资源版本不匹配。")
    }
  }

  func prepare(_ dependencies: Dependencies, deadline: TimeInterval) async throws -> ProcessIdentity
  {
    var lastError: any Error = AppFailure.timedOut
    while ProcessInfo.processInfo.systemUptime < deadline {
      let matches = NSRunningApplication.runningApplications(
        withBundleIdentifier: dependencies.ghosttyIdentifier)
      guard matches.count <= 1 else { throw AppFailure.message("检测到多个 Ghostty 应用实例，请先保留一个。") }
      let application: NSRunningApplication
      if let existing = matches.first {
        guard
          existing.bundleURL?.resolvingSymlinksInPath()
            == dependencies.ghostty.resolvingSymlinksInPath()
        else { throw AppFailure.message("运行中的 Ghostty 与设置选择的位置不同，请先检查设置。") }
        application = existing
      } else {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--initial-window=false"]
        configuration.activates = false
        application = try await launch(dependencies.ghostty, configuration, deadline: deadline)
      }
      do {
        if !application.isTerminated,
          let identity = try ProcessIdentity.read(application.processIdentifier)
        {
          return identity
        }
      } catch {
        lastError = error
      }
      // Closing the last finished terminal can leave a terminating app in Launch Services briefly.
      try await Task.sleep(for: .milliseconds(50))
    }
    throw lastError
  }

  func create(
    _ dependencies: Dependencies, command: String, directory: URL, timeout: TimeInterval,
    onCreated: (OwnedTerminal) throws -> Void
  ) async throws -> OwnedTerminal {
    try requireRunning(dependencies)
    guard let executable = Bundle.main.executableURL else {
      throw AppFailure.message("无法确定应用的原生启动入口。")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    let launch = try TerminalLaunch(command: command, executable: executable)
    defer { launch.cancel() }
    let reply = try call(
      "createsession", [dependencies.ghostty.path, launch.command, directory.path], timeout: timeout
    )
    let terminal = try decodeTerminal(reply)
    try onCreated(terminal)
    try await launch.start(in: terminal, until: deadline)
    return terminal
  }

  /// Consent can wait indefinitely; it must neither block AppKit nor consume a command timeout.
  func authorize(_ dependencies: Dependencies) async throws {
    let application = try requireRunning(dependencies)
    let pid = application.processIdentifier
    let identity = try ProcessIdentity.read(pid)
    let status = await Task.detached {
      let target = NSAppleEventDescriptor(processIdentifier: pid)
      return AEDeterminePermissionToAutomateTarget(
        target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    }.value
    guard status == noErr else {
      throw GhosttyFailure(code: status, detail: "自动化授权检查失败。")
    }
    guard !application.isTerminated, let identity, try ProcessIdentity.read(pid) == identity,
      try requireRunning(dependencies).processIdentifier == pid
    else { throw AppFailure.message("等待授权期间 Ghostty 实例已改变，请重新打开文件。") }
  }

  func terminal(
    _ dependencies: Dependencies, id: String?, matching pids: [Int32], timeout: TimeInterval
  ) async throws -> OwnedTerminal {
    try requireRunning(dependencies)
    let rows = try call("readterminals", [dependencies.ghostty.path, id ?? ""], timeout: timeout)
    let devices = try pids.compactMap(ProcessIdentity.terminalDevice)
    var matches: [OwnedTerminal] = []
    for index in 1...max(1, rows.numberOfItems) {
      guard let row = rows.atIndex(index) else { continue }
      let terminal = try decodeTerminal(row)
      guard id == nil || terminal.id == id else { continue }
      if try terminal.containsClient(on: devices) {
        matches.append(terminal)
      }
    }
    guard matches.count == 1, let match = matches.first else {
      throw AppFailure.message("无法将已登记编辑器与唯一的 Ghostty 终端关联。")
    }
    return match
  }

  func focus(_ dependencies: Dependencies, terminalID: String, timeout: TimeInterval) async throws {
    try requireRunning(dependencies)
    guard
      try call("focusterminal", [dependencies.ghostty.path, terminalID], timeout: timeout)
        .booleanValue
    else {
      throw AppFailure.message("未能确认 Ghostty 已聚焦自建终端。")
    }
  }

  func closeFinished(_ dependencies: Dependencies, terminalID: String) throws -> Bool {
    try requireRunning(dependencies)
    return try call("closefinished", [dependencies.ghostty.path, terminalID], timeout: 2)
      .booleanValue
  }

  @discardableResult
  private func requireRunning(_ dependencies: Dependencies) throws -> NSRunningApplication {
    let matches = NSRunningApplication.runningApplications(
      withBundleIdentifier: dependencies.ghosttyIdentifier)
    guard matches.count == 1, let application = matches.first, !application.isTerminated,
      application.bundleURL?.resolvingSymlinksInPath()
        == dependencies.ghostty.resolvingSymlinksInPath(),
      FileManager.default.fileExists(atPath: dependencies.ghostty.path)
    else {
      throw AppFailure.message(
        "原 Ghostty 路径或运行实例无法核验。请修复原位置后重试：\(dependencies.ghostty.path)")
    }
    return application
  }

  private func launch(
    _ url: URL, _ configuration: NSWorkspace.OpenConfiguration, deadline: TimeInterval
  ) async throws -> NSRunningApplication {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else { throw AppFailure.timedOut }
    return try await withCheckedThrowingContinuation { continuation in
      let waiting = ApplicationLaunch(continuation)
      let timeout = Task {
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        waiting.finish(.failure(AppFailure.timedOut))
      }
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
        Task { @MainActor in
          timeout.cancel()
          if let app {
            waiting.finish(.success(app))
          } else {
            waiting.finish(.failure(error ?? AppFailure.message("Ghostty 启动未返回应用实例。")))
          }
        }
      }
    }
  }

  private func decodeTerminal(_ row: NSAppleEventDescriptor) throws -> OwnedTerminal {
    guard let id = row.atIndex(1)?.stringValue, !id.isEmpty,
      let pid = row.atIndex(2)?.int32Value, pid >= 0,
      let tty = row.atIndex(3)?.stringValue, !tty.isEmpty
    else { throw AppFailure.message("Ghostty 返回的终端信息不完整。") }
    return OwnedTerminal(id: id, pid: pid, tty: tty)
  }

  private func call(_ handler: String, _ arguments: [String], timeout: TimeInterval? = nil) throws
    -> NSAppleEventDescriptor
  {
    // AppleScript timeouts use whole seconds; do not round up beyond the remaining budget.
    if let timeout, timeout < 1 { throw AppFailure.timedOut }
    let event = NSAppleEventDescriptor(
      eventClass: 0x6173_6372, eventID: 0x7073_6272, targetDescriptor: nil,
      returnID: -1, transactionID: 0)
    event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: 0x736e_616d)
    let values = NSAppleEventDescriptor.list()
    for (index, argument) in arguments.enumerated() {
      values.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
    }
    if let timeout {
      values.insert(NSAppleEventDescriptor(int32: Int32(timeout)), at: arguments.count + 1)
    }
    event.setParam(values, forKeyword: 0x2d2d_2d2d)
    var error: NSDictionary?
    let reply = script.executeAppleEvent(event, error: &error)
    guard error == nil else {
      let detail = error?[NSAppleScript.errorMessage] as? String ?? "未知 AppleEvent 错误"
      let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.int32Value
      throw GhosttyFailure(code: code, detail: detail)
    }
    return reply
  }
}

/// NSWorkspace cannot cancel a submitted launch; a late callback must not resume creation.
@MainActor private final class ApplicationLaunch {
  private var continuation: CheckedContinuation<NSRunningApplication, any Error>?

  init(_ continuation: CheckedContinuation<NSRunningApplication, any Error>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<NSRunningApplication, any Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}
