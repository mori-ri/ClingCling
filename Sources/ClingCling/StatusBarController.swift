import AppKit
import ApplicationServices
import Combine

/// メニューバーアイコンとメニュー（仕様 §32）
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let openPopup: () -> Void
    private let openSettings: () -> Void
    private var pauseItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var permissionSeparator: NSMenuItem!
    private var cancellable: AnyCancellable?

    init(model: AppModel, openPopup: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.openPopup = openPopup
        self.openSettings = openSettings
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        permissionItem = NSMenuItem(title: "⚠️ アクセシビリティ権限を許可…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionSeparator = .separator()
        menu.addItem(permissionItem)
        menu.addItem(permissionSeparator)
        let open = NSMenuItem(title: "Open Clipboard", action: #selector(openClipboard), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(open)
        pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(settings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit ClingCling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        cancellable = model.settings.$isPaused.sink { [weak self] paused in self?.updateIcon(paused: paused) }
    }

    private func updateIcon(paused: Bool) {
        // .app ではロゴのテンプレート画像、swift run など Resources が無い場合は SF Symbol
        let logo = NSImage(named: "MenuBarIconTemplate")
        let image = paused || logo == nil
            ? NSImage(systemSymbolName: paused ? "pause.circle" : "doc.on.clipboard", accessibilityDescription: "ClingCling")
            : logo
        image?.isTemplate = true
        image?.accessibilityDescription = "ClingCling"
        statusItem.button?.image = image
        pauseItem?.title = paused ? "Resume Capture" : "Pause Capture"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let granted = AXIsProcessTrusted()
        permissionItem.isHidden = granted
        permissionSeparator.isHidden = granted
    }

    @objc private func openAccessibilitySettings() { ActionExecutor.openAccessibilitySettings() }
    @objc private func openClipboard() { openPopup() }
    @objc private func settings() { openSettings() }
    @objc private func togglePause() { model.settings.isPaused.toggle() }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "履歴を消去しますか？"
        alert.informativeText = "Pin した Item は残ります。この操作は取り消せません。"
        alert.addButton(withTitle: "消去")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.clearHistory() }
    }
}
