import Darwin
import Foundation

/// Coordinates a new terminal's layout before executing its original editor command.
@MainActor final class TerminalLaunch {
  let command: String
  private let directory: String
  private let listener: Int32
  private var client: Int32 = -1
  private var cancelled = false

  init(command: String, executable: URL) throws {
    var template = Array("/private/tmp/fn-launch.XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else { throw launchFailure() }
    directory = String(cString: created)
    let path = directory + "/ready.sock"
    self.command = [executable.path, "--launch-editor", path, command]
      .map(CommandRunner.quote).joined(separator: " ")
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    do {
      guard listener >= 0, fcntl(listener, F_SETFD, FD_CLOEXEC) == 0,
        fcntl(listener, F_SETFL, O_NONBLOCK) == 0
      else { throw launchFailure() }
      var address = try socketAddress(path)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, listen(listener, 1) == 0 else { throw launchFailure() }
    } catch {
      if listener >= 0 { Darwin.close(listener) }
      unlink(path)
      rmdir(directory)
      throw error
    }
  }

  /// Creation has returned, but AppKit may still be resizing its new surface.
  func start(in terminal: OwnedTerminal, until deadline: TimeInterval) async throws {
    do {
      guard !cancelled else { throw CancellationError() }
      while client < 0 {
        client = accept(listener, nil, nil)
        if client >= 0 { break }
        guard errno == EAGAIN || errno == EINTR else { throw launchFailure() }
        try await pause(until: deadline)
      }
      guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
        fcntl(client, F_SETFL, O_NONBLOCK) == 0
      else { throw launchFailure() }
      ignoreBrokenPipe(client)
      var hello = Data()
      while hello.last != 10 {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(client, &buffer, buffer.count, 0)
        if count > 0 {
          hello.append(contentsOf: buffer.prefix(count))
          guard hello.count < 1024 else { throw launchFailure() }
        } else if count == 0 {
          throw launchFailure()
        } else if errno != EAGAIN && errno != EINTR {
          throw launchFailure()
        }
        try await pause(until: deadline)
      }
      guard String(data: hello, encoding: .utf8) == terminal.tty + "\n",
        terminal.tty.hasPrefix("/dev/")
      else { throw AppFailure.message("新终端的启动握手与 Ghostty 返回的 TTY 不一致。") }
      let tty = open(terminal.tty, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | O_NOFOLLOW)
      guard tty >= 0 else { throw launchFailure() }
      defer { Darwin.close(tty) }
      var previous: (UInt16, UInt16)?
      var stableSince = ProcessInfo.processInfo.systemUptime
      while true {
        try await pause(until: deadline)
        var byte: UInt8 = 0
        let connected = recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        guard connected < 0 && (errno == EAGAIN || errno == EINTR) else {
          throw launchFailure()
        }
        var size = winsize()
        guard ioctl(tty, TIOCGWINSZ, &size) == 0 else { throw launchFailure() }
        let now = ProcessInfo.processInfo.systemUptime
        if previous?.0 != size.ws_row || previous?.1 != size.ws_col {
          previous = (size.ws_row, size.ws_col)
          stableSince = now
        }
        // Require 100 ms without a size change, within the caller's creation deadline.
        if size.ws_row > 0, size.ws_col > 0, now - stableSince >= 0.1 { break }
      }
      try Task.checkCancellation()
      guard !cancelled else { throw CancellationError() }
      var permission: UInt8 = 1
      guard send(client, &permission, 1, 0) == 1 else { throw launchFailure() }
    } catch {
      cancel()
      throw error
    }
  }

  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    if client >= 0 { Darwin.close(client) }
    Darwin.close(listener)
    unlink(directory + "/ready.sock")
    rmdir(directory)
  }

  private func pause(until deadline: TimeInterval) async throws {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppFailure.timedOut }
    try await Task.sleep(for: .milliseconds(10))
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppFailure.timedOut }
  }

  /// Runs before AppKit loads; initializes the login environment only after coordination succeeds.
  static func execute(arguments: [String]) throws -> Never {
    guard arguments.count == 2 else { throw launchFailure() }
    let path = arguments[0]
    let directory = (path as NSString).deletingLastPathComponent
    let prefix = "/private/tmp/fn-launch."
    var folder = stat()
    var entry = stat()
    guard path == directory + "/ready.sock", directory.hasPrefix(prefix),
      directory.dropFirst(prefix.count).count == 6,
      directory.dropFirst(prefix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
      lstat(directory, &folder) == 0, folder.st_uid == getuid(),
      folder.st_mode & S_IFMT == S_IFDIR, folder.st_mode & 0o077 == 0,
      lstat(path, &entry) == 0, entry.st_uid == getuid(), entry.st_mode & S_IFMT == S_IFSOCK
    else { throw launchFailure() }
    // The parent may die without running cancel(); its waiting child shares cleanup ownership.
    defer {
      unlink(path)
      rmdir(directory)
    }
    guard let input = ttyname(STDIN_FILENO).map({ String(cString: $0) }),
      let output = ttyname(STDOUT_FILENO).map({ String(cString: $0) }), input == output
    else { throw launchFailure() }
    let connection = socket(AF_UNIX, SOCK_STREAM, 0)
    guard connection >= 0 else { throw launchFailure() }
    defer { Darwin.close(connection) }
    ignoreBrokenPipe(connection)
    guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0 else { throw launchFailure() }
    var address = try socketAddress(arguments[0])
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw launchFailure() }
    let hello = Array((input + "\n").utf8)
    guard hello.withUnsafeBytes({ send(connection, $0.baseAddress, $0.count, 0) }) == hello.count
    else { throw launchFailure() }
    var waiting = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
    guard poll(&waiting, 1, 10_000) > 0 else { throw AppFailure.timedOut }
    var permission: UInt8 = 0
    guard recv(connection, &permission, 1, 0) == 1, permission == 1 else { throw launchFailure() }
    let shell =
      ProcessInfo.processInfo.environment["SHELL"]
      ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) }
      ?? "/bin/zsh"
    guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
      throw AppFailure.message("登录 shell 无法执行：\(shell)。尚未执行 Neovim。")
    }
    // Login profiles supply tool paths, but may also change directory. Restore the request's cwd
    // before exec so the first files keep their original argv and startup behavior.
    let command =
      "builtin cd -- " + CommandRunner.quote(FileManager.default.currentDirectoryPath)
      + " && exec " + arguments[1]
    let values = [shell, "-l", "-c", command].map { strdup($0) }
    defer { for value in values { free(value) } }
    var argv = values + [nil]
    unlink(path)
    rmdir(directory)  // A successful exec does not run Swift defers.
    execv(shell, &argv)
    throw launchFailure()
  }
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let bytes = Array(path.utf8CString)
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw launchFailure() }
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
  }
  return address
}

private func ignoreBrokenPipe(_ socket: Int32) {
  var enabled: Int32 = 1
  _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func launchFailure() -> AppFailure {
  .message("专用终端的启动协调失败；尚未执行 Neovim，请检查终端后重试。")
}
