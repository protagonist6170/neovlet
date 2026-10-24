import Darwin
import Foundation

struct EditorIdentity: Equatable, Sendable {
  let pid: Int32
  let endpoint: String
  let terminalPIDs: [Int32]
}

@MainActor protocol NeovimAccess {
  func identify(endpoint: URL, executable: URL, timeout: TimeInterval) async throws
    -> EditorIdentity
  func deliver(_ files: [URL], endpoint: URL, executable: URL) async throws
  func verify(_ files: [URL], endpoint: URL, executable: URL, pid: Int32, timeout: TimeInterval)
    async throws
}

/// Only contacts an endpoint allocated by this app; filenames never become RPC source code.
@MainActor struct Neovim: NeovimAccess {
  let runner = CommandRunner()
  private static let identityExpression =
    #"json_encode([getpid(),v:servername,luaeval("(function() local p={} for _,u in ipairs(vim.api.nvim_list_uis()) do if u.stdin_tty and u.stdout_tty then local c=vim.api.nvim_get_chan_info(u.chan).client local a=c and c.attributes if a and a.pid then table.insert(p,a.pid) else table.insert(p,vim.fn.getpid()) end end end return p end)()")])"#
  private static let receiptExpression =
    "json_encode([getpid(),map(getbufinfo(),{_,v -> v.name}),argv()])"

  func identify(endpoint: URL, executable: URL, timeout: TimeInterval) async throws
    -> EditorIdentity
  {
    var info = stat()
    guard lstat(endpoint.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
      info.st_uid == getuid()
    else { throw AppFailure.message("自建会话的 RPC socket 尚未就绪或身份无效。") }
    let reply = try await client(
      executable, endpoint, ["--remote-expr", Self.identityExpression], timeout: timeout)
    let value = try JSONDecoder().decode(IdentityReply.self, from: Data(reply.utf8))
    guard value.endpoint == endpoint.path, !value.terminalPIDs.isEmpty else {
      throw AppFailure.message("RPC 未确认到指定地址上的终端编辑器。")
    }
    return EditorIdentity(
      pid: value.pid, endpoint: value.endpoint, terminalPIDs: value.terminalPIDs)
  }

  func deliver(_ files: [URL], endpoint: URL, executable: URL) async throws {
    _ = try await client(executable, endpoint, ["--remote"] + files.map(\.path), timeout: 5)
  }

  func verify(_ files: [URL], endpoint: URL, executable: URL, pid: Int32, timeout: TimeInterval)
    async throws
  {
    let reply = try await client(
      executable, endpoint, ["--remote-expr", Self.receiptExpression], timeout: timeout)
    let receipt = try JSONDecoder().decode(Receipt.self, from: Data(reply.utf8))
    let buffers = Set(receipt.buffers.filter { $0.hasPrefix("/") }.map(Self.canonical))
    let received = buffers.union(receipt.arguments.filter { $0.hasPrefix("/") }.map(Self.canonical))
    guard receipt.pid == pid,
      files.first.map({ buffers.contains(Self.canonical($0.path)) }) ?? true,
      Set(files.map { Self.canonical($0.path) }).isSubset(of: received)
    else { throw AppFailure.message("未能确认编辑器已接收这批文件。文件可能已送达，请检查编辑器。") }
  }

  private func client(
    _ executable: URL, _ endpoint: URL, _ arguments: [String], timeout: TimeInterval = 2
  ) async throws -> String {
    let result = try await runner.run(
      [executable.path, "--headless", "-u", "NONE", "-i", "NONE", "--server", endpoint.path]
        + arguments, timeout: timeout)
    guard result.status == 0, result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AppFailure.message("Neovim RPC 未成功：" + result.error.prefix(500))
    }
    return result.output
  }

  private static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private struct IdentityReply: Decodable {
    let pid: Int32
    let endpoint: String
    let terminalPIDs: [Int32]
    init(from decoder: any Decoder) throws {
      var values = try decoder.unkeyedContainer()
      pid = try values.decode(Int32.self)
      endpoint = try values.decode(String.self)
      terminalPIDs = try values.decode([Int32].self)
    }
  }

  private struct Receipt: Decodable {
    let pid: Int32
    let buffers: [String]
    let arguments: [String]
    init(from decoder: any Decoder) throws {
      var values = try decoder.unkeyedContainer()
      pid = try values.decode(Int32.self)
      buffers = try values.decode([String].self)
      arguments = try values.decode([String].self)
    }
  }
}
