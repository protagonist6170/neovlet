import Darwin
import Foundation
import Testing

@testable import Neovlet

@Suite @MainActor struct TerminalLaunchTests {
  @Test func waitsForTerminalLayoutAndPreservesTheInitialArguments() async throws {
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = directory.appendingPathComponent("receipt")
    let tools = directory.appendingPathComponent("login tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let runtime = tools.appendingPathComponent("neovlet-test-runtime")
    try Data("#!/bin/sh\n[ \"$NEOVLET_LOGIN_ENVIRONMENT\" = ready ]\n".utf8).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    let profile = """
      export PATH=\(CommandRunner.quote(tools.path)):$PATH
      export NEOVLET_LOGIN_ENVIRONMENT=ready
      /usr/bin/touch \(CommandRunner.quote(journal.path + ".profile"))
      cd /
      """
    try Data(profile.utf8).write(to: directory.appendingPathComponent(".zprofile"))
    let editor = directory.appendingPathComponent("fake nvim ' executable")
    let source = directory.appendingPathComponent("editor.c")
    let script = """
      #include <sys/ioctl.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <unistd.h>
      int main(int argc, char **argv) {
        if (system("/usr/bin/env neovlet-test-runtime") != 0) return 6;
        struct winsize size;
        if (ioctl(0, TIOCGWINSZ, &size) != 0) return 2;
        const char *prefix = getenv("NEOVLET_TEST_RECEIPT");
        char path[4096], cwd[4096];
        snprintf(path, sizeof(path), "%s.arguments", prefix);
        FILE *output = fopen(path, "wb");
        if (!output) return 3;
        for (int i = 1; i < argc; ++i) fwrite(argv[i], 1, strlen(argv[i]) + 1, output);
        fclose(output);
        snprintf(path, sizeof(path), "%s.directory", prefix);
        output = fopen(path, "w");
        if (!output || !getcwd(cwd, sizeof(cwd))) return 4;
        fprintf(output, "%s\\n", cwd);
        fclose(output);
        snprintf(path, sizeof(path), "%s.size", prefix);
        output = fopen(path, "w");
        if (!output) return 5;
        fprintf(output, "%u %u\\n", size.ws_row, size.ws_col);
        fclose(output);
        return 0;
      }
      """
    try Data(script.utf8).write(to: source)
    let compilation = try await CommandRunner().run([
      "/usr/bin/xcrun", "clang", source.path, "-o", editor.path,
    ])
    try #require(compilation.status == 0, "\(compilation.error)")
    let arguments = [
      "--listen", directory.appendingPathComponent("test.sock").path, "--",
      directory.appendingPathComponent("中文 ' $(literal);\nfirst.txt").path,
      directory.appendingPathComponent("-second[1].txt").path,
    ]
    let original = ([editor.path] + arguments).map(CommandRunner.quote).joined(separator: " ")
    let launch = try TerminalLaunch(command: original, executable: try applicationExecutable())
    defer { launch.cancel() }
    let tty = try TestTerminal()
    defer { tty.close() }
    try tty.resize(columns: 50, rows: 20)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exec " + launch.command]
    process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging([
      "NEOVLET_TEST_RECEIPT": journal.path,
      "SHELL": "/bin/zsh", "ZDOTDIR": directory.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]) { _, new in new }
    process.standardInput = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    process.standardOutput = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    process.standardError = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    // Ghostty can launch its command before its create call returns and layout settles.
    let creationDeadline = ProcessInfo.processInfo.systemUptime + 1
    while process.isRunning && ProcessInfo.processInfo.systemUptime < creationDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!FileManager.default.fileExists(atPath: journal.path + ".size"))
    #expect(!FileManager.default.fileExists(atPath: journal.path + ".profile"))
    try tty.resize(columns: 140, rows: 40)
    let starting = Task {
      try await launch.start(
        in: OwnedTerminal(id: "test", pid: process.processIdentifier, tty: tty.path),
        until: ProcessInfo.processInfo.systemUptime + 2)
    }
    try await Task.sleep(for: .milliseconds(25))
    try tty.resize(columns: 180, rows: 50)
    try await starting.value
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!process.isRunning)
    try #require(process.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: journal.path + ".profile"))
    let receivedArguments = try Data(contentsOf: URL(fileURLWithPath: journal.path + ".arguments"))
      .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    let receivedDirectory = try String(
      contentsOfFile: journal.path + ".directory", encoding: .utf8
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let size = try String(contentsOfFile: journal.path + ".size", encoding: .utf8)
      .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    #expect(receivedArguments == arguments)
    let canonical = try #require(realpath(directory.path, nil))
    defer { free(canonical) }
    #expect(receivedDirectory == String(cString: canonical))
    #expect(size == [50, 180])
  }

  enum Failure: Sendable { case timeout, unstableLayout, cancellation, wrongTerminal }

  @Test func waitingBranchRemovesAnOrphanedHandshakeWithoutExecutingTheEditor() async throws {
    var template = Array("/private/tmp/fn-launch.XXXXXX".utf8CString)
    let created = try #require(mkdtemp(&template))
    let directory = URL(fileURLWithPath: String(cString: created))
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("ready.sock").path
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(path.utf8CString).map { UInt8(bitPattern: $0) })
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    Darwin.close(listener)  // Models a parent dying before the child connects.
    try #require(bound == 0)
    let tty = try TestTerminal()
    defer { tty.close() }
    let receipt = directory.appendingPathComponent("must-not-execute")
    let process = Process()
    process.executableURL = try applicationExecutable()
    process.arguments = [
      "--launch-editor", path, "/usr/bin/touch " + CommandRunner.quote(receipt.path),
    ]
    process.standardInput = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    process.standardOutput = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    process.standardError = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus != 0)
    #expect(!FileManager.default.fileExists(atPath: receipt.path))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test(arguments: [Failure.timeout, .unstableLayout, .cancellation, .wrongTerminal])
  func failedCoordinationNeverExecutesTheEditor(_ failure: Failure) async throws {
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipt = directory.appendingPathComponent("must-not-exist")
    let profileReceipt = directory.appendingPathComponent("must-not-initialize")
    try Data(("/usr/bin/touch " + CommandRunner.quote(profileReceipt.path)).utf8)
      .write(to: directory.appendingPathComponent(".zprofile"))
    let original = "/usr/bin/touch " + CommandRunner.quote(receipt.path)
    let launch = try TerminalLaunch(command: original, executable: try applicationExecutable())
    defer { launch.cancel() }
    let tty = try TestTerminal()
    defer { tty.close() }
    try tty.resize(columns: 50, rows: 20)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exec " + launch.command]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "SHELL": "/bin/zsh", "ZDOTDIR": directory.path,
    ]) { _, new in new }
    process.standardInput = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    process.standardOutput = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    process.standardError = FileHandle(fileDescriptor: tty.slave, closeOnDealloc: false)
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    let starting = Task {
      try await launch.start(
        in: OwnedTerminal(
          id: "test", pid: process.processIdentifier,
          tty: failure == .wrongTerminal ? "/dev/null" : tty.path),
        until: ProcessInfo.processInfo.systemUptime
          + (failure == .timeout ? 0.05 : failure == .unstableLayout ? 0.4 : 2))
    }
    if failure == .cancellation {
      try await Task.sleep(for: .milliseconds(50))
      starting.cancel()
    }
    if failure == .unstableLayout {
      for columns: UInt16 in [60, 70, 80, 90, 100, 110, 120, 130, 140, 150] {
        try await Task.sleep(for: .milliseconds(50))
        try tty.resize(columns: columns, rows: 20)
      }
    }
    do {
      try await starting.value
      Issue.record("不完整的启动协调不应允许编辑器执行。")
    } catch {
      // The child must observe cancellation/EOF as well as the parent reporting failure.
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!process.isRunning)
    #expect(!FileManager.default.fileExists(atPath: receipt.path))
    #expect(!FileManager.default.fileExists(atPath: profileReceipt.path))
  }
}

private func applicationExecutable() throws -> URL {
  var parent = Bundle(for: TestBundleMarker.self).bundleURL
  for _ in 0..<6 {
    let candidate = parent.appendingPathComponent("Neovlet")
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    parent.deleteLastPathComponent()
  }
  throw AppFailure.message("找不到 SwiftPM 构建的原生入口。")
}

private final class TestBundleMarker: NSObject {}

private final class TestTerminal {
  var master: Int32 = -1
  var slave: Int32 = -1
  let path: String

  init() throws {
    guard openpty(&master, &slave, nil, nil, nil) == 0, let name = ttyname(slave) else {
      throw AppFailure.message("无法分配测试伪终端。")
    }
    path = String(cString: name)
  }

  func resize(columns: UInt16, rows: UInt16) throws {
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
    guard ioctl(slave, TIOCSWINSZ, &size) == 0 else {
      throw AppFailure.message("无法设置测试终端尺寸。")
    }
  }

  func close() {
    Darwin.close(master)
    Darwin.close(slave)
  }
}
