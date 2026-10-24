import AppKit
import UniformTypeIdentifiers

/// A single small window serves first-run setup, explicit preferences and dependency repair.
@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let settings: Settings
  private let ghosttyField = NSTextField()
  private let neovimField = NSTextField()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "验证并保存", target: nil, action: nil)
  var onOpen: (() -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?
  private var saved = false
  private var validationID = UUID()

  init(settings: Settings) {
    self.settings = settings
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Neovlet 设置"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    ghosttyField.placeholderString = "自动发现，或选择 Ghostty.app"
    neovimField.placeholderString = "自动发现，或选择 nvim 可执行文件"
    let description = NSTextField(
      wrappingLabelWithString:
        "选择已安装的 Ghostty 和 Neovim。新设置用于下次创建，已有会话保留原路径。关闭此窗口会取消尚未处理的打开请求。首次控制 Ghostty 时会请求自动化授权。")
    description.textColor = .secondaryLabelColor
    let ghosttyButton = NSButton(title: "选择…", target: self, action: #selector(chooseGhostty))
    let neovimButton = NSButton(title: "选择…", target: self, action: #selector(chooseNeovim))
    saveButton.target = self
    saveButton.action = #selector(validateAndSave)
    saveButton.keyEquivalent = "\r"
    let detect = NSButton(title: "重新检测", target: self, action: #selector(detect))
    let copy = NSButton(title: "复制诊断", target: self, action: #selector(copyDiagnostics))
    let controls = NSStackView(views: [detect, copy, saveButton])
    controls.spacing = 12
    let stack = NSStackView(views: [
      description, NSTextField(labelWithString: "Ghostty 应用"),
      row(ghosttyField, ghosttyButton), NSTextField(labelWithString: "Neovim 可执行文件"),
      row(neovimField, neovimButton), status, controls,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)
    if let content = window.contentView {
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        description.widthAnchor.constraint(equalTo: stack.widthAnchor),
      ])
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func show(problem: String? = nil) {
    if window?.isVisible == true {
      if let problem { status.stringValue = problem }
      NSApp.activate()
      window?.makeKeyAndOrderFront(nil)
      return
    }
    onOpen?()
    validationID = UUID()
    saveButton.isEnabled = true
    saved = false
    ghosttyField.stringValue = settings.preferences.ghosttyPath
    neovimField.stringValue = settings.preferences.neovimPath
    status.stringValue = problem ?? settings.loadProblem ?? "空路径将尝试自动发现。"
    window?.center()
    showWindow(nil)
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    validationID = UUID()
    if !saved { onCancel?() }
  }

  private func row(_ field: NSTextField, _ button: NSButton) -> NSView {
    let row = NSStackView(views: [field, button])
    row.spacing = 8
    field.widthAnchor.constraint(equalToConstant: 430).isActive = true
    return row
  }

  @objc private func chooseGhostty() { choose(application: true) }
  @objc private func chooseNeovim() { choose(application: false) }

  private func choose(application: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    // Preserve package-manager entry points across dependency upgrades.
    panel.resolvesAliases = false
    if application { panel.allowedContentTypes = [.applicationBundle] }
    if panel.runModal() == .OK, let url = panel.url {
      (application ? ghosttyField : neovimField).stringValue = url.path
    }
  }

  @objc private func detect() {
    ghosttyField.stringValue = ""
    neovimField.stringValue = ""
    status.stringValue = "点击验证并保存以重新发现依赖。"
  }

  @objc private func validateAndSave() {
    let identifier = UUID()
    validationID = identifier
    let value = Preferences(
      ghosttyPath: ghosttyField.stringValue, neovimPath: neovimField.stringValue)
    saveButton.isEnabled = false
    status.stringValue = "正在验证…"
    Task {
      defer { if validationID == identifier { saveButton.isEnabled = true } }
      do {
        let dependencies = try await settings.resolve(value)
        guard validationID == identifier, window?.isVisible == true else { return }
        guard ghosttyField.stringValue == value.ghosttyPath,
          neovimField.stringValue == value.neovimPath
        else {
          status.stringValue = "路径已修改，请重新验证并保存。"
          return
        }
        try settings.save(
          Preferences(
            ghosttyPath: dependencies.ghostty.path, neovimPath: dependencies.neovim.path))
        saved = true
        close()
        onSave?()
      } catch {
        if validationID == identifier { status.stringValue = error.localizedDescription }
      }
    }
  }

  @objc private func copyDiagnostics() {
    let text =
      "Neovlet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")\n"
      + "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
      + "Ghostty: \(ghosttyField.stringValue)\nNeovim: \(neovimField.stringValue)\n"
      + status.stringValue
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
