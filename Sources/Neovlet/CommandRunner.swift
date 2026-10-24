import Darwin
import Foundation

enum AppFailure: Error, LocalizedError, Sendable {
  case message(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .message(let text): text
    case .timedOut: "操作超过时限；没有自动重新投递或创建会话。"
    }
  }
}

struct CommandResult: Sendable {
  let status: Int32
  let output: String
  let error: String
}

/// Executes an argv vector off the UI thread, with bounded output collection and child reaping.
struct CommandRunner: Sendable {
  func run(_ arguments: [String], timeout: TimeInterval = 3) async throws -> CommandResult {
    try await Task.detached { try Self.execute(arguments, timeout: timeout) }.value
  }

  private static func execute(_ arguments: [String], timeout: TimeInterval) throws -> CommandResult
  {
    guard let executable = arguments.first, timeout > 0 else { throw AppFailure.timedOut }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(
      "neovlet-command-" + UUID().uuidString)
    try files.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    for url in [outputURL, errorURL] {
      guard
        files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw AppFailure.message("无法创建命令输出文件。") }
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let error = try FileHandle(forWritingTo: errorURL)
    defer { try? error.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(arguments.dropFirst())
    process.standardInput = FileHandle.nullDevice
    // Files avoid pipe-buffer deadlocks and inherited-pipe EOF waits after timeout.
    process.standardOutput = output
    process.standardError = error
    try process.run()
    while process.isRunning {
      if ProcessInfo.processInfo.systemUptime >= deadline {
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.05
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw AppFailure.timedOut
      }
      usleep(5_000)
    }
    process.waitUntilExit()
    guard let stdout = String(data: try Data(contentsOf: outputURL), encoding: .utf8),
      let stderr = String(data: try Data(contentsOf: errorURL), encoding: .utf8)
    else { throw AppFailure.message("命令输出不是有效 UTF-8。") }
    return CommandResult(status: process.terminationStatus, output: stdout, error: stderr)
  }

  /// Quotes one shell argument for Ghostty's command string; RPC uses argv directly.
  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
