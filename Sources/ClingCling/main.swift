import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var popup: PopupController!
    private var statusBar: StatusBarController!
    private var settingsWindow: NSWindow?
    private var settingsForm: SettingsFormState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        do {
            model = try AppModel(settings: settings)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "ClingCling を起動できませんでした")
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        settingsForm = SettingsFormState()
        let vm = PopupViewModel(model: model)
        popup = PopupController(vm: vm)
        vm.openSettings = { [weak self] in self?.showSettings() }
        statusBar = StatusBarController(model: model,
                                        openPopup: { [weak self] in self?.popup.show() },
                                        openSettings: { [weak self] page in self?.showSettings(page: page) })
        let hotKey = HotKey { [weak self] in
            DispatchQueue.main.async { self?.popup.toggle() }
        }
        hotKey.register(settings.shortcut)
        model.hotKey = hotKey
        model.start()
        askAboutUpdateChecksIfNeeded()

        #if DEBUG
        // 開発用: CLINGCLING_SNAPSHOT=/path/to.png でポップアップを開いて画像を書き出す
        if let path = ProcessInfo.processInfo.environment["CLINGCLING_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.popup.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.popup.writeSnapshot(to: path) }
            }
        }
        // 開発用: CLINGCLING_APPEARANCE=dark / light で外観を固定する
        if let name = ProcessInfo.processInfo.environment["CLINGCLING_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        // 開発用: CLINGCLING_SETTINGS_PAGE=ai などで起動時に設定を開く（ページは SettingsFormState が読む）
        if ProcessInfo.processInfo.environment["CLINGCLING_SETTINGS_PAGE"] != nil { showSettings() }
        // 開発用: CLINGCLING_SETTINGS_SNAPSHOT=/path/to.png で設定ウインドウを画像に書き出す
        if let path = ProcessInfo.processInfo.environment["CLINGCLING_SETTINGS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let view = self?.settingsWindow?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
    }

    /// 新しいバージョンを自動で確認するか、2 回目の起動時に一度だけ聞く。既定はオフなので、
    /// 許可した人のほかは GitHub に問い合わせない。
    private func askAboutUpdateChecksIfNeeded() {
        // `swift run` ではバージョンがなく、確認しても何もしない
        guard model.updates.currentVersion != nil else { return }
        #if DEBUG
        // 画面の書き出しなど、開発用の環境変数を付けた起動では聞かない
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("CLINGCLING_") }) { return }
        #endif
        guard model.settings.shouldAskAboutUpdateChecks() else { return }
        // 起動の直後はほかのアプリが前面にあるので、少し待ってから出す
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "新しいバージョンを自動で確認しますか？")
            alert.informativeText = String(localized: "起動時と 1 日に 1 回、GitHub にリリースの一覧を問い合わせ、新しいバージョンが出たらメニューバーでお知らせします。コピーした内容や設定は送りません。あとから 設定 › 一般 で変更できます。")
            alert.addButton(withTitle: String(localized: "確認する"))
            alert.addButton(withTitle: String(localized: "確認しない"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.model.settings.checksForUpdates = true
            Task { await self.model.updates.check() }
        }
    }

    /// 設定ウインドウを開く。`page` を渡すとそのページに切り替える（nil なら前回のページのまま）。
    func showSettings(page: SettingsPageID? = nil) {
        popup.hide()
        if let page { settingsForm.page = page }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: model.settings, model: model, form: settingsForm)))
            window.title = "ClingCling Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // タイトルバーを隠し、信号機ボタンをサイドバーの内側に置く（WindowButtonsInset）
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(SettingsView.defaultSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Dock に表示しないメニューバー常駐アプリ（.app では Info.plist の LSUIElement でも指定）
    app.setActivationPolicy(.accessory)
    app.run()
}
