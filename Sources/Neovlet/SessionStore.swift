import CryptoKit
import Darwin
import Foundation

struct ProcessIdentity: Codable, Equatable, Sendable {
  let pid: Int32
  let startedSeconds: UInt64
  let startedMicroseconds: UInt64

  /// A targeted observation, never a system-wide process scan. Unknown is an error.
  static func read(_ pid: Int32) throws -> ProcessIdentity? {
    guard let info = try information(pid) else { return nil }
    return ProcessIdentity(
      pid: pid, startedSeconds: info.pbi_start_tvsec,
      startedMicroseconds: info.pbi_start_tvusec)
  }

  static func terminalDevice(_ pid: Int32) throws -> dev_t? {
    guard try read(pid) != nil else { return nil }
    var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&query, 4, &info, &size, nil, 0) == 0 else {
      throw AppFailure.message("无法读取已确认 TUI 的控制 TTY。")
    }
    if size == 0 { return nil }
    guard size == MemoryLayout<kinfo_proc>.size, info.kp_eproc.e_ucred.cr_uid == getuid() else {
      throw AppFailure.message("TUI 的进程信息或用户身份无法核验。")
    }
    return info.kp_eproc.e_tdev == -1 ? nil : info.kp_eproc.e_tdev
  }

  private static func information(_ pid: Int32) throws -> proc_bsdinfo? {
    guard pid > 0 else { throw AppFailure.message("登记的进程编号无效。") }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    if count == size {
      guard info.pbi_uid == getuid() else {
        throw AppFailure.message("目标进程不属于当前用户。")
      }
      if info.pbi_status == SZOMB { return nil }
      return info
    }
    // macOS may stop exposing proc_bsdinfo before the parent reaps an exited process.
    // kill(0) still succeeds in that interval; only a confirmed zombie counts as dead.
    var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var exited = kinfo_proc()
    var exitedSize = MemoryLayout<kinfo_proc>.size
    if sysctl(&query, 4, &exited, &exitedSize, nil, 0) == 0 {
      if exitedSize == MemoryLayout<kinfo_proc>.size,
        exited.kp_eproc.e_ucred.cr_uid == getuid(), exited.kp_proc.p_stat == SZOMB
      {
        return nil
      }
    }
    if kill(pid, 0) == -1 && errno == ESRCH { return nil }
    throw AppFailure.message("无法确认进程 \(pid) 的身份；没有将它当作已退出。")
  }
}

struct Registration: Codable, Equatable, Sendable {
  enum Phase: String, Codable { case preparing, starting, ready }
  var version = 1
  let id: UUID
  let endpoint: URL
  let dependencies: Dependencies
  var phase: Phase = .preparing
  var ghostty: ProcessIdentity?
  var terminalID: String?
  var editor: ProcessIdentity?
}

@MainActor protocol SessionStoring {
  func load() throws -> Registration?
  func allocate(using dependencies: Dependencies) throws -> Registration
  func save(_ registration: Registration) throws
  func clear(_ id: UUID) throws
  func forget() throws
}

struct RegistrationConflict: Error, LocalizedError {
  let records: [Registration]
  var errorDescription: String? { "会话登记身份冲突；保留已知事实，未覆盖或清理登记。" }
}

/// Owns one namespace, its process lock and atomic registration; never deletes foreign paths.
@MainActor final class SessionStore: SessionStoring {
  let directory: URL
  let socketDirectory: URL
  enum StorageStep {
    case beforeReplacement, afterReplacement, beforeFileSync, afterUnlink, beforeDirectorySync
  }
  enum StorageOperation {
    case save(Registration)
    case clear(UUID)
    case forget
  }
  typealias Checkpoint = (StorageOperation, StorageStep) throws -> Void

  private let checkpoint: Checkpoint
  private let lock: Int32
  private var registrationURL: URL { directory.appendingPathComponent("session.json") }

  init(
    namespace: String, root: URL? = nil,
    checkpoint: @escaping Checkpoint = { _, _ in }
  ) throws {
    self.checkpoint = checkpoint
    let files = FileManager.default
    let base =
      try root
      ?? files.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    directory = base.appendingPathComponent(namespace, isDirectory: true)
    try files.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let digest = SHA256.hash(data: Data(namespace.utf8)).prefix(8)
      .map { String(format: "%02x", $0) }.joined()
    socketDirectory = URL(fileURLWithPath: "/private/tmp/fn-\(getuid())-\(digest)")
    if !files.fileExists(atPath: socketDirectory.path) {
      try files.createDirectory(
        at: socketDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    var info = stat()
    guard lstat(socketDirectory.path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
    else { throw AppFailure.message("会话 socket 目录不是当前用户的私有目录。") }
    lock = Darwin.open(
      directory.appendingPathComponent("instance.lock").path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw AppFailure.message("无法打开应用实例锁。") }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      close(lock)
      throw AppFailure.message("此版本的 Neovlet 已有运行实例，请使用已有实例。")
    }
  }

  deinit { close(lock) }

  func load() throws -> Registration? {
    var info = stat()
    if lstat(registrationURL.path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw AppFailure.message("无法检查会话登记；没有将它当作不存在。")
    }
    let value: Registration
    do {
      value = try JSONDecoder().decode(Registration.self, from: Data(contentsOf: registrationURL))
    } catch { throw AppFailure.message("会话登记损坏或无法读取。请检查旧编辑器，再使用会话恢复。") }
    guard value.version == 1,
      value.endpoint == socketDirectory.appendingPathComponent(value.id.uuidString + ".sock"),
      value.phase != .ready
        || (value.editor != nil && value.ghostty != nil && value.terminalID != nil)
    else { throw AppFailure.message("会话登记版本或内容无效；没有自动清空它。") }
    return value
  }

  func allocate(using dependencies: Dependencies) throws -> Registration {
    let id = UUID()
    return Registration(
      id: id, endpoint: socketDirectory.appendingPathComponent(id.uuidString + ".sock"),
      dependencies: dependencies)
  }

  func save(_ registration: Registration) throws {
    let operation = StorageOperation.save(registration)
    let data = try JSONEncoder().encode(registration)
    try checkpoint(operation, .beforeReplacement)
    try data.write(to: registrationURL, options: .atomic)
    try checkpoint(operation, .afterReplacement)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: registrationURL.path)
    let handle = try FileHandle(forWritingTo: registrationURL)
    defer { try? handle.close() }
    try checkpoint(operation, .beforeFileSync)
    try handle.synchronize()
    try synchronizeDirectory(operation)
  }

  /// Absence still needs a directory sync: an earlier unlink may not have been confirmed.
  func clear(_ id: UUID) throws {
    let operation = StorageOperation.clear(id)
    if let current = try load() {
      guard current.id == id else { throw RegistrationConflict(records: [current]) }
      try FileManager.default.removeItem(at: registrationURL)
      try checkpoint(operation, .afterUnlink)
      var info = stat()
      if lstat(current.endpoint.path, &info) == 0,
        info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK
      {
        try? FileManager.default.removeItem(at: current.endpoint)
      }
    }
    try synchronizeDirectory(operation)
  }

  /// Explicit user recovery discards only the record; unverified sockets remain untouched.
  func forget() throws {
    var info = stat()
    if lstat(registrationURL.path, &info) == 0 {
      try FileManager.default.removeItem(at: registrationURL)
      try checkpoint(.forget, .afterUnlink)
    } else if errno != ENOENT {
      throw AppFailure.message("无法检查待清除的会话登记。")
    }
    try synchronizeDirectory(.forget)
  }

  private func synchronizeDirectory(_ operation: StorageOperation) throws {
    try checkpoint(operation, .beforeDirectorySync)
    let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw AppFailure.message("无法打开登记目录以确认耐久写入。") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw AppFailure.message("登记目录同步失败，提交结果尚未确认。") }
  }
}
