import AppKit
import Foundation

struct Dependencies: Codable, Equatable, Sendable {
  let ghostty: URL
  let neovim: URL
  let ghosttyIdentifier: String
}

struct Preferences: Codable, Equatable, Sendable {
  var version = 1
  var ghosttyPath = ""
  var neovimPath = ""
}

/// Resolves user choices without launching Ghostty or relying on Finder's PATH.
@MainActor final class Settings {
  static let ghosttyIdentifier = "com.mitchellh.ghostty"
  private let file: URL
  private let runner: CommandRunner
  private let ghosttyCandidates: () -> [URL]
  private let neovimCandidates: [URL]
  var preferences: Preferences
  private(set) var loadProblem: String?

  init(
    directory: URL, runner: CommandRunner = CommandRunner(),
    ghosttyCandidates: (() -> [URL])? = nil, neovimCandidates: [URL]? = nil
  ) throws {
    file = directory.appendingPathComponent("settings.json")
    self.runner = runner
    self.ghosttyCandidates =
      ghosttyCandidates ?? {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Self.ghosttyIdentifier)
      }
    self.neovimCandidates =
      neovimCandidates
      ?? [
        "/opt/homebrew/bin/nvim", "/usr/local/bin/nvim",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/nvim")
          .path,
      ].map { URL(fileURLWithPath: $0) }
    if FileManager.default.fileExists(atPath: file.path) {
      do {
        preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
        if preferences.version != 1 {
          loadProblem = "用户配置版本不受支持，请在设置中重新选择依赖。"
          preferences = Preferences()
        }
      } catch {
        preferences = Preferences()
        loadProblem = "用户配置无法读取，请在设置中重新选择依赖。原配置尚未覆盖。"
      }
    } else {
      preferences = Preferences()
    }
  }

  func save(_ value: Preferences) throws {
    try JSONEncoder().encode(value).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    preferences = value
    loadProblem = nil
  }

  func resolve(_ value: Preferences? = nil) async throws -> Dependencies {
    if value == nil, let loadProblem { throw AppFailure.message(loadProblem) }
    let value = value ?? preferences
    let ghostty: URL
    if value.ghosttyPath.isEmpty {
      let candidates = Array(Set(ghosttyCandidates().map { $0.standardizedFileURL }))
      guard candidates.count == 1, let only = candidates.first else {
        throw AppFailure.message("未找到唯一的 Ghostty，请在设置中选择应用。")
      }
      ghostty = only
    } else {
      guard value.ghosttyPath.hasPrefix("/") else { throw AppFailure.message("Ghostty 路径必须是绝对路径。") }
      ghostty = URL(fileURLWithPath: value.ghosttyPath)
    }
    guard let bundle = Bundle(url: ghostty), bundle.bundleIdentifier == Self.ghosttyIdentifier,
      let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path)
    else { throw AppFailure.message("所选路径不是可运行的 Ghostty 应用。") }
    let dictionary = ghostty.appendingPathComponent("Contents/Resources/Ghostty.sdef")
    let parser = try GhosttyDictionary(data: Data(contentsOf: dictionary))
    guard parser.supportsRequiredOperations else {
      throw AppFailure.message("此 Ghostty 缺少所需的终端创建、身份查询或聚焦能力，请升级后重试。")
    }
    let neovim: URL
    if value.neovimPath.isEmpty {
      let existing = neovimCandidates.filter {
        FileManager.default.isExecutableFile(atPath: $0.path)
      }
      guard existing.count == 1, let only = existing.first else {
        throw AppFailure.message("未找到唯一的 Neovim，请在设置中选择可执行文件。")
      }
      neovim = only
    } else {
      guard value.neovimPath.hasPrefix("/") else { throw AppFailure.message("Neovim 路径必须是绝对路径。") }
      neovim = URL(fileURLWithPath: value.neovimPath)
    }
    guard FileManager.default.isExecutableFile(atPath: neovim.path) else {
      throw AppFailure.message("Neovim 路径已失效，请重新选择。")
    }
    let version = try await runner.run([neovim.path, "--version"])
    let number = version.output.split(separator: "\n").first?.split(separator: " ").last
    let parts = number?.dropFirst().split(separator: ".") ?? []
    guard version.status == 0, version.output.hasPrefix("NVIM v"), parts.count >= 2,
      let major = Int(parts[0]), let minor = Int(parts[1]), major > 0 || minor >= 11
    else { throw AppFailure.message("需要支持此 RPC 协议的 Neovim 0.11 或更新版本。") }
    return Dependencies(ghostty: ghostty, neovim: neovim, ghosttyIdentifier: Self.ghosttyIdentifier)
  }
}

private final class GhosttyDictionary: NSObject, XMLParserDelegate {
  private var commands: Set<String> = []
  private var terminalProperties: Set<String> = []
  private var configurationProperties: Set<String> = []
  private var applicationProperties: Set<String> = []
  private var scope = ""

  var supportsRequiredOperations: Bool {
    Set(["new window", "new tab", "new surface configuration", "focus", "close"]).isSubset(
      of: commands)
      && applicationProperties.contains("front window")
      && Set(["id", "pid", "tty"]).isSubset(of: terminalProperties)
      && Set(["command", "initial working directory", "wait after command"])
        .isSubset(of: configurationProperties)
  }

  init(data: Data) throws {
    super.init()
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else { throw AppFailure.message("Ghostty 脚本字典无法解析。") }
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if elementName == "class" || elementName == "record-type" { scope = attributes["name"] ?? "" }
    if elementName == "command", let name = attributes["name"] { commands.insert(name) }
    if elementName == "property", let name = attributes["name"] {
      if scope == "terminal" { terminalProperties.insert(name) }
      if scope == "application" { applicationProperties.insert(name) }
      if scope == "surface configuration" { configurationProperties.insert(name) }
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    if elementName == "class" || elementName == "record-type" { scope = "" }
  }
}
