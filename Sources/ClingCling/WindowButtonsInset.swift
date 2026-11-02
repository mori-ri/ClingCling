import AppKit
import SwiftUI

/// 信号機ボタンを右下へずらし、浮いたサイドバーの角丸の上ではなく内側に置く。
/// AppKit はリサイズ・キー状態の変化・フルスクリーンの切り替えでボタンを並べ直すので、
/// そのたびに既定の位置からずらし直す。
struct WindowButtonsInset: NSViewRepresentable {
    var dx: CGFloat
    var dy: CGFloat

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(offset: CGSize(width: dx, height: dy))
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        private let offset: CGSize
        private var defaults: [NSWindow.ButtonType: NSPoint] = [:]
        private var applied: [NSWindow.ButtonType: NSPoint] = [:]
        private var observers: [NSObjectProtocol] = []

        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        init(offset: CGSize) {
            self.offset = offset
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleApply() }
                })
            }
            if let titlebar = window.standardWindowButton(.closeButton)?.superview {
                titlebar.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: titlebar, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleApply() }
                })
            }
            apply()
        }

        /// 通知の時点では AppKit がまだレイアウト中のことがある
        private func scheduleApply() {
            apply()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for type in Self.types {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = button.frame.origin
                // 自分が置いた位置と違えば、AppKit が並べ直したということ
                if applied[type] != origin { defaults[type] = origin }
                guard let base = defaults[type] else { continue }
                let target = NSPoint(x: base.x + offset.width, y: base.y - offset.height)
                if origin != target { button.setFrameOrigin(target) }
                applied[type] = target
            }
        }
    }
}
