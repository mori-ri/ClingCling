import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var popup: PopupController!
    private var statusBar: StatusBarController!
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        do {
            model = try AppModel(settings: settings)
        } catch {
            let alert = NSAlert()
            alert.messageText = "ClingCling を起動できませんでした"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let vm = PopupViewModel(model: model)
        popup = PopupController(vm: vm)
        vm.openSettings = { [weak self] in self?.showSettings() }
        statusBar = StatusBarController(model: model,
                                        openPopup: { [weak self] in self?.popup.show() },
                                        openSettings: { [weak self] in self?.showSettings() })
        hotKey = HotKey { [weak self] in
            DispatchQueue.main.async { self?.popup.toggle() }
        }
        model.start()

        #if DEBUG
        // 開発用: CLINGCLING_SNAPSHOT=/path/to.png でポップアップを開いて画像を書き出す
        if let path = ProcessInfo.processInfo.environment["CLINGCLING_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.popup.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.popup.writeSnapshot(to: path) }
            }
        }
        #endif
    }

    func showSettings() {
        popup.hide()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: model.settings, model: model)))
            window.title = "ClingCling Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
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
