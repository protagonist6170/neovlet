import Foundation
import Testing

@testable import Neovlet

@Suite @MainActor struct SettingsTests {
  @Test func missingFrontWindowCapabilityIsRejectedBeforeLaunchingGhostty() async throws {
    let fixture = try SettingsFixture(frontWindow: false)
    defer { fixture.clean() }
    let settings = try fixture.settings()
    await #expect(throws: AppFailure.self) { _ = try await settings.resolve() }
  }

  @Test func explicitSymlinkChoiceSurvivesSavingAndReopening() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.clean() }
    let alias = fixture.root.appendingPathComponent("stable nvim")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.neovim)
    let settings = try fixture.settings()
    let value = Preferences(ghosttyPath: fixture.ghostty.path, neovimPath: alias.path)
    let dependencies = try await settings.resolve(value)
    #expect(dependencies.neovim == alias)
    try settings.save(value)
    let reopened = try fixture.settings()
    #expect(try await reopened.resolve() == dependencies)
  }

  @Test func damagedPreferencesCanBeExplicitlyRepaired() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.clean() }
    let file = fixture.root.appendingPathComponent("settings.json")
    try Data("broken".utf8).write(to: file)
    let settings = try fixture.settings()
    await #expect(throws: AppFailure.self) { _ = try await settings.resolve() }
    #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    let choice = Preferences(ghosttyPath: fixture.ghostty.path, neovimPath: fixture.neovim.path)
    _ = try await settings.resolve(choice)
    try settings.save(choice)
    #expect(try await settings.resolve().neovim == fixture.neovim)
  }

  @Test func ambiguousAutomaticDiscoveryRequiresAnExplicitChoice() async throws {
    let fixture = try SettingsFixture()
    defer { fixture.clean() }
    let settings = try Settings(
      directory: fixture.root,
      ghosttyCandidates: { [fixture.ghostty, URL(fileURLWithPath: "/other/Ghostty.app")] },
      neovimCandidates: [fixture.neovim])
    await #expect(throws: AppFailure.self) { _ = try await settings.resolve() }
    _ = try await settings.resolve(
      Preferences(ghosttyPath: fixture.ghostty.path, neovimPath: fixture.neovim.path))
  }

  @Test func separateConfigurationDirectoriesDoNotShareChoices() throws {
    let fixture = try SettingsFixture()
    defer { fixture.clean() }
    let other = try testDirectory()
    defer { try? FileManager.default.removeItem(at: other) }
    let candidate = try fixture.settings()
    try candidate.save(Preferences(neovimPath: fixture.neovim.path))
    let independent = try Settings(
      directory: other, ghosttyCandidates: { [] }, neovimCandidates: [])
    #expect(independent.preferences == Preferences())
  }
}

struct SettingsFixture {
  let root: URL
  let ghostty: URL
  let neovim: URL

  init(frontWindow: Bool = true) throws {
    root = try testDirectory()
    ghostty = root.appendingPathComponent("Ghostty.app")
    neovim = root.appendingPathComponent("nvim")
    let contents = ghostty.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    let executable = contents.appendingPathComponent("MacOS/Ghostty")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.mitchellh.ghostty", "CFBundleExecutable": "Ghostty",
        "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0
    ).write(to: contents.appendingPathComponent("Info.plist"))
    let dictionary = """
      <dictionary><suite name="Ghostty">
      <class name="application">\(frontWindow ? "<property name=\"front window\"/>" : "")</class>
      <class name="terminal"><property name="id"/><property name="pid"/><property name="tty"/></class>
      <record-type name="surface configuration"><property name="command"/>
      <property name="initial working directory"/><property name="wait after command"/></record-type>
      <command name="new window"/><command name="new tab"/><command name="new surface configuration"/>
      <command name="focus"/><command name="close"/></suite></dictionary>
      """
    try Data(dictionary.utf8).write(to: contents.appendingPathComponent("Resources/Ghostty.sdef"))
    try Data("#!/bin/sh\nprintf 'NVIM v0.11.0\\n'\n".utf8).write(to: neovim)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: neovim.path)
  }

  @MainActor func settings() throws -> Settings {
    try Settings(directory: root, ghosttyCandidates: { [ghostty] }, neovimCandidates: [neovim])
  }

  func clean() { try? FileManager.default.removeItem(at: root) }
}
