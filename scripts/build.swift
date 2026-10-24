import Foundation

struct BuildError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

struct Builder {
  let root: URL
  let output: URL
  let options: [String: String]
  var distribution: Bool { options["--distribution"] != nil }

  func run() throws {
    let ghostty = URL(fileURLWithPath: options["--ghostty"] ?? "/Applications/Ghostty.app")
    guard
      FileManager.default.fileExists(
        atPath: ghostty.appendingPathComponent("Contents/Resources/Ghostty.sdef").path)
    else { throw BuildError("找不到构建用 Ghostty 字典；可使用 --ghostty /path/Ghostty.app。") }
    let identity = options["--identity"] ?? "-"
    if distribution
      && (identity == "-" || options["--version"] == nil || options["--build-number"] == nil)
    {
      throw BuildError("正式构建需要 --identity、--version 和 --build-number。")
    }
    let packageArguments = [
      "--package-path", root.path, "--scratch-path",
      output.appendingPathComponent("swift-build").path,
      "--cache-path", output.appendingPathComponent("cache").path,
      "--config-path", output.appendingPathComponent("config").path,
      "--security-path", output.appendingPathComponent("security").path,
      "--disable-sandbox", "-c", "release", "--arch", "arm64",
    ]
    _ = try command("/usr/bin/xcrun", ["swift", "build"] + packageArguments)
    let binaryPath = try command(
      "/usr/bin/xcrun", ["swift", "build"] + packageArguments + ["--show-bin-path"]
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let app = output.appendingPathComponent("Neovlet.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    let resources = contents.appendingPathComponent("Resources")
    for directory in [macOS, resources] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let binary = macOS.appendingPathComponent("Neovlet")
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: binaryPath).appendingPathComponent("Neovlet"), to: binary)
    let dictionaryPath = ghostty.path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    let script = try String(
      contentsOf: root.appendingPathComponent("Resources/Ghostty.applescript"), encoding: .utf8)
    let stagedScript = output.appendingPathComponent("Ghostty.applescript")
    try
      ("using terms from application \"\(dictionaryPath)\"\n" + script + "\nend using terms from\n")
      .write(to: stagedScript, atomically: true, encoding: .utf8)
    _ = try command(
      "/usr/bin/osacompile",
      ["-o", resources.appendingPathComponent("Ghostty.scpt").path, stagedScript.path])
    guard
      var plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil)
        as? [String: Any]
    else { throw BuildError("应用清单不是有效字典。") }
    // Preserve existing isolated candidate settings, registrations and explicit --candidate-id values.
    let candidateID =
      options["--candidate-id"] ?? "local.finder-neovim.candidate.\(UUID().uuidString.lowercased())"
    guard candidateID.hasPrefix("local.finder-neovim.candidate."),
      candidateID.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
      })
    else { throw BuildError("候选标识必须在 local.finder-neovim.candidate 命名空间中。") }
    if !distribution { plist["CFBundleIdentifier"] = candidateID }
    if let version = options["--version"] { plist["CFBundleShortVersionString"] = version }
    if let number = options["--build-number"] { plist["CFBundleVersion"] = number }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    var signing = [
      "--force", "--sign", identity, "--options", "runtime", "--entitlements",
      root.appendingPathComponent("Resources/Neovlet.entitlements").path,
    ]
    if distribution { signing.append("--timestamp") }
    _ = try command("/usr/bin/codesign", signing + [app.path])
    _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    if distribution {
      let signature = try command("/usr/bin/codesign", ["-dvv", app.path])
      guard signature.contains("Authority=Developer ID Application:"),
        signature.contains("Timestamp=")
      else {
        throw BuildError("正式构建缺少 Developer ID Application 签名或可信时间戳。")
      }
    }
    guard try command(binary.path, ["--self-check"]).hasPrefix("PASS:") else {
      throw BuildError("原生入口与编译脚本资源检查失败。")
    }
    print("PASS：原生入口、薄 adapter、Hardened Runtime 与严格签名检查。")
    print("构建没有安装、注册或启动编辑会话；正式分发另需完成公证。")
    print(app.path)
  }

  private func command(_ executable: String, _ arguments: [String]) throws -> String {
    let log = output.appendingPathComponent("command-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
      throw BuildError("无法创建构建日志。")
    }
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    let text = try String(contentsOf: log, encoding: .utf8)
    guard process.terminationStatus == 0 else {
      throw BuildError("\(executable) 失败：\n\(text)\n日志：\(log.path)")
    }
    return text
  }
}

do {
  var arguments = Array(CommandLine.arguments.dropFirst())
  guard !arguments.isEmpty else { throw BuildError("请使用 bash scripts/build.sh。") }
  let output = URL(fileURLWithPath: arguments.removeFirst())
  var options: [String: String] = [:]
  let valueOptions: Set<String> = [
    "--ghostty", "--identity", "--version", "--build-number", "--candidate-id",
  ]
  while !arguments.isEmpty {
    let key = arguments.removeFirst()
    if key == "--distribution" {
      options[key] = "true"
    } else if valueOptions.contains(key), !arguments.isEmpty {
      options[key] = arguments.removeFirst()
    } else {
      throw BuildError("未知或不完整参数：\(key)")
    }
  }
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  try Builder(root: root, output: output, options: options).run()
} catch {
  FileHandle.standardError.write(Data("构建失败：\(error)\n".utf8))
  exit(1)
}
