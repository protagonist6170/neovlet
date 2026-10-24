import Foundation
import Testing

@testable import Neovlet

@Suite @MainActor struct CompatibilityTests {
  @Test func renamedAppRestoresLegacySettingsAndRegisteredSession() async throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let plist = try Data(contentsOf: project.appendingPathComponent("Resources/Info.plist"))
    let document = try PropertyListSerialization.propertyList(from: plist, format: nil)
    let metadata = try #require(document as? [String: Any])
    let identifier = try #require(metadata["CFBundleIdentifier"] as? String)
    // Changing this identity would strand existing state before either JSON file is read.
    #expect(identifier == "local.finder-neovim")

    let root = try testDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Keep this test isolated from the installed app's actual namespace and socket directory.
    let namespace = identifier + ".candidate.compat-" + UUID().uuidString.lowercased()
    let store = try SessionStore(namespace: namespace, root: root)
    defer { try? FileManager.default.removeItem(at: store.socketDirectory) }
    let settingsURL = store.directory.appendingPathComponent("settings.json")
    let settingsJSON = """
      {"version":1,"ghosttyPath":"/Previously Selected/Ghostty.app","neovimPath":"/legacy/bin/nvim"}
      """
    try Data(settingsJSON.utf8).write(to: settingsURL)
    let id = UUID()
    let endpoint = store.socketDirectory.appendingPathComponent(id.uuidString + ".sock")
    // Freeze v1's wire representation rather than encoding it with the current model.
    let registrationJSON = """
      {
        "version":1,"id":"\(id.uuidString)","endpoint":"\(endpoint.absoluteString)",
        "dependencies":{
          "ghostty":"file:///Ghostty.app","neovim":"file:///nvim",
          "ghosttyIdentifier":"test.ghostty"
        },
        "phase":"ready","terminalID":"owned",
        "ghostty":{"pid":10,"startedSeconds":100,"startedMicroseconds":0},
        "editor":{"pid":20,"startedSeconds":200,"startedMicroseconds":0}
      }
      """
    try Data(registrationJSON.utf8).write(
      to: store.directory.appendingPathComponent("session.json"))

    let settings = try Settings(directory: store.directory)
    #expect(settings.loadProblem == nil)
    #expect(settings.preferences.ghosttyPath == "/Previously Selected/Ghostty.app")
    #expect(settings.preferences.neovimPath == "/legacy/bin/nvim")
    let fixture = SessionFixture()
    let session = fixture.makeSession(store: store)
    #expect(
      try await fixture.perform(on: session, .activate, using: fixture.dependencies) == .focused)
    let recovered = try #require(try store.load())
    #expect(recovered.id == id)
    #expect(recovered.endpoint == endpoint)
    #expect(recovered.dependencies == fixture.dependencies)
    #expect(recovered.ghostty == fixture.application)
    #expect(recovered.editor == fixture.editor)
    #expect(recovered.terminalID == "owned")
    #expect(recovered.phase == .ready)
    #expect(fixture.resolutions == 0)
    #expect(fixture.ghostty.creates == 0)
    #expect(fixture.ghostty.focuses == 1)
    #expect(try String(contentsOf: settingsURL, encoding: .utf8) == settingsJSON)
  }
}
