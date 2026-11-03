import AppKit
import ApplicationServices
import Combine

/// メニューバーアイコンとメニュー
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let openPopup: () -> Void
    private let openSettings: (SettingsPageID?) -> Void
    private var openItem: NSMenuItem!
    private var downloadItem: NSMenuItem!
    private var whatsNewItem: NSMenuItem!
    private var updateSeparator: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var permissionSeparator: NSMenuItem!
    private var cancellable: AnyCancellable?

    init(model: AppModel, openPopup: @escaping () -> Void, openSettings: @escaping (SettingsPageID?) -> Void) {
        self.model = model
        self.openPopup = openPopup
        self.openSettings = openSettings
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        permissionItem = NSMenuItem(title: String(localized: "⚠️ アクセシビリティ権限を許可…"), action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionSeparator = .separator()
        menu.addItem(permissionItem)
        menu.addItem(permissionSeparator)
        downloadItem = NSMenuItem(title: "", action: #selector(downloadUpdate), keyEquivalent: "")
        whatsNewItem = NSMenuItem(title: String(localized: "新機能を見る…"), action: #selector(openNews), keyEquivalent: "")
        updateSeparator = .separator()
        menu.addItem(downloadItem)
        menu.addItem(whatsNewItem)
        menu.addItem(updateSeparator)
        openItem = NSMenuItem(title: String(localized: "クリップボードを開く"), action: #selector(openClipboard), keyEquivalent: "")
        menu.addItem(openItem)
        pauseItem = NSMenuItem(title: String(localized: "キャプチャを一時停止"), action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: String(localized: "履歴を消去…"), action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "お知らせ…"), action: #selector(openNews), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "設定…"), action: #selector(settings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: String(localized: "フィードバック・要望を送る…"), action: #selector(sendFeedback), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "ClingCling を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        pauseItem?.title = paused ? String(localized: "キャプチャを再開") : String(localized: "キャプチャを一時停止")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let granted = AXIsProcessTrusted()
        permissionItem.isHidden = granted
        permissionSeparator.isHidden = granted
        let version = model.updates.availableVersion
        if let version {
            downloadItem.title = String(localized: "新しいバージョン \(version) をダウンロード")
        }
        for item in [downloadItem, whatsNewItem, updateSeparator] { item?.isHidden = version == nil }
        // メニューの表示だけなので、1 文字で表せないキーは添えない
        let shortcut = model.settings.shortcut
        openItem.keyEquivalent = shortcut.keyEquivalent ?? ""
        openItem.keyEquivalentModifierMask = shortcut.menuModifiers
    }

    @objc private func openAccessibilitySettings() { ActionExecutor.openAccessibilitySettings() }
    @objc private func sendFeedback() { ProjectLinks.open(ProjectLinks.newFeedback) }
    @objc private func openClipboard() { openPopup() }
    @objc private func settings() { openSettings(nil) }
    @objc private func openNews() { openSettings(.news) }
    @objc private func downloadUpdate() { ProjectLinks.open(ProjectLinks.latestRelease) }
    @objc private func togglePause() { model.settings.isPaused.toggle() }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "履歴を消去しますか？")
        alert.informativeText = String(localized: "Pin した Item は残ります。この操作は取り消せません。")
        alert.addButton(withTitle: String(localized: "消去"))
        alert.addButton(withTitle: String(localized: "キャンセル"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.clearHistory() }
    }
}
