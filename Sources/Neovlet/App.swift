import AppKit

@main @MainActor enum NeovletApp {
  static func main() {
    if CommandLine.arguments.dropFirst().first == "--launch-editor" {
      do {
        try TerminalLaunch.execute(arguments: Array(CommandLine.arguments.dropFirst(2)))
      } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
      }
    }
    do {
      guard let scriptURL = Bundle.main.url(forResource: "Ghostty", withExtension: "scpt") else {
        throw AppFailure.message("请从构建生成的 Neovlet.app 启动，缺少 Ghostty.scpt 资源。")
      }
      let ghostty = try Ghostty(scriptURL: scriptURL)
      if CommandLine.arguments.contains("--self-check") {
        print("PASS: native executable, bundled adapter v1, no external app events")
        return
      }
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let delegate = try AppDelegate(ghostty: ghostty)
      application.delegate = delegate
      withExtendedLifetime(delegate) { application.run() }
    } catch {
      if CommandLine.arguments.contains("--self-check") {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
      }
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let alert = NSAlert()
      alert.messageText = "Neovlet 无法启动"
      alert.informativeText = error.localizedDescription
      application.activate()
      alert.runModal()
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store: SessionStore
  private let settings: Settings
  private let ghostty: Ghostty
  private lazy var session = Session(
    store: store, ghostty: ghostty, neovim: Neovim(),
    resolveDependencies: { [settings] in try await settings.resolve() },
    notify: { [weak self] event in self?.handle(event) })
  private let settingsWindow: SettingsWindow
  private var statusItem: NSStatusItem?
  private var launched = false
  private var receivedFiles = false
  private var deferredActivation = false

  init(ghostty: Ghostty) throws {
    guard let identifier = Bundle.main.bundleIdentifier else {
      throw AppFailure.message("应用缺少 bundle identifier。")
    }
    // Persistent state follows the stable bundle identifier, independent of the app's name.
    store = try SessionStore(namespace: identifier)
    settings = try Settings(directory: store.directory)
    self.ghostty = ghostty
    settingsWindow = SettingsWindow(settings: settings)
    super.init()
    settingsWindow.onOpen = { [weak self] in self?.session.settingsOpened() }
    settingsWindow.onSave = { [weak self] in self?.session.settingsClosed(.saved) }
    settingsWindow.onCancel = { [weak self] in self?.session.settingsClosed(.cancelled) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    launched = true
    installMainMenu()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "terminal", accessibilityDescription: "Neovlet")
    let menu = NSMenu()
    for (title, action) in [
      ("设置…", #selector(showSettings)), ("会话恢复…", #selector(recover)),
      ("退出管理程序", #selector(quit)),
    ] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      menu.addItem(entry)
    }
    item.menu = menu
    statusItem = item
    let normalLaunch =
      notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false
    if !receivedFiles && (normalLaunch || deferredActivation) { session.submit(.activate) }
    session.applicationReady()
  }

  /// Accessory windows still need standard responder-chain editing and close shortcuts.
  private func installMainMenu() {
    let menu = NSMenu()
    let applicationMenu = NSMenu(title: "Neovlet")
    let quitItem = NSMenuItem(title: "退出管理程序", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    applicationMenu.addItem(quitItem)
    let editMenu = NSMenu(title: "编辑")
    for (title, action, key) in [
      ("剪切", #selector(NSText.cut(_:)), "x"),
      ("拷贝", #selector(NSText.copy(_:)), "c"),
      ("粘贴", #selector(NSText.paste(_:)), "v"),
      ("全选", #selector(NSText.selectAll(_:)), "a"),
    ] {
      editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
    }
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(
      withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    for submenu in [applicationMenu, editMenu, windowMenu] {
      menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
    }
    NSApp.mainMenu = menu
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    receivedFiles = true
    session.submit(.files(urls))
  }

  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if launched { session.submit(.activate) } else { deferredActivation = true }
    return false
  }

  private func handle(_ event: Session.Event) {
    switch event {
    case .settingsRequired(let problem): settingsWindow.show(problem: problem.detail)
    case .report(let report, let presentation):
      defer { session.presentationClosed(presentation) }
      switch report {
      case .request(let report):
        switch report.result {
        case .completed: break
        case .notPerformed(let problem): present(problem.detail)
        case .focusFailed(let confirmed, let problem):
          let fact = confirmed == .filesDelivered ? "文件已确认送达，但聚焦未完成。" : "会话已就绪，但聚焦未完成。"
          present(fact + "\n" + problem.detail)
        }
      case .stopped(let report):
        var message = report.problem.detail
        if let current = report.current {
          let fact: String
          switch current.operation {
          case .creation: fact = "终端可能已创建，初始文件接收尚未确认。"
          case .delivery: fact = "文件可能已送达，接收尚未确认。"
          case .sessionVerification: fact = "会话核验尚未完成。"
          }
          message +=
            "\n\n" + fact + "没有自动重放或另建会话。\n本次请求（请核实结果）：\n"
            + describe([current.request])
        }
        if !report.notProcessed.isEmpty {
          message += "\n\n以下请求尚未处理，请检查会话后重新打开：\n" + describe(report.notProcessed)
        }
        present(message)
      case .cancelled: break
      case .recovery(let result):
        switch result {
        case .forgotten: break
        case .failed(let problem): present(problem.detail)
        case .refused(let reason):
          switch reason {
          case .busy: present("仍有请求正在处理或等待，请稍后恢复。")
          case .editorStillRunning: present("旧编辑器仍在运行，请先关闭它，或继续使用原会话。")
          case .endpointStillResponding: present("旧 RPC 仍在响应，请先关闭旧编辑器。")
          }
        }
      case .quitRefused: present("当前操作尚未完成，请稍后退出管理程序。")
      }
    case .terminationSuggested:
      if session.requestTermination(.automatic) == .allow { NSApp.terminate(nil) }
    }
  }

  private func describe(_ requests: [Session.Request]) -> String {
    requests.map { request in
      request.files.isEmpty ? "聚焦／空启动请求" : request.files.map(\.path).joined(separator: "\n")
    }.joined(separator: "\n")
  }

  private func present(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Neovlet 未完成操作"
    alert.informativeText = message
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "设置…")
    NSApp.activate()
    if alert.runModal() == .alertSecondButtonReturn { showSettings() }
  }

  @objc private func showSettings() { settingsWindow.show() }

  @objc private func recover() {
    let presentation = session.presentationOpened()
    defer { session.presentationClosed(presentation) }
    let alert = NSAlert()
    alert.messageText = "恢复自建会话"
    alert.informativeText =
      "先检查 Ghostty 中的编辑器。重新核验不会重放旧请求；没有可用会话时会创建空编辑器。只有确认旧会话已关闭后，才清理登记；清理不会终止进程。"
    alert.addButton(withTitle: "重新核验")
    alert.addButton(withTitle: "旧会话已关闭，清理登记")
    alert.addButton(withTitle: "取消")
    NSApp.activate()
    switch alert.runModal() {
    case .alertFirstButtonReturn: session.submit(.activate)
    case .alertSecondButtonReturn: session.forgetAfterUserConfirmation()
    default: break
    }
  }

  @objc private func quit() { NSApp.terminate(nil) }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    session.requestTermination(.userRequested) == .allow ? .terminateNow : .terminateCancel
  }
}
