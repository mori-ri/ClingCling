import AppKit
import ApplicationServices
import SwiftUI

/// フォーカスを奪わずにキー入力を受けられるパネル。
/// 直前のアプリが前面のまま残るので、Copy 後の ⌘V がそのアプリに届く。
final class PopupPanel: NSPanel {
    /// 表示位置の基準。内容に合わせてサイズが変わっても、リストの角をここに留める。
    struct Anchor {
        /// リストの左上（`growsUp` なら左下）を置く画面上の点
        var point: NSPoint
        var growsUp: Bool
        var visibleFrame: NSRect
    }

    var anchor: Anchor?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        // 影は SwiftUI 側で描く（透明な余白ごと影が付かないように）
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard let anchor else { return super.setFrame(frameRect, display: flag) }
        super.setFrame(NSRect(origin: origin(for: frameRect.size, anchor: anchor), size: frameRect.size), display: flag)
    }

    private func origin(for size: NSSize, anchor: Anchor) -> NSPoint {
        let margin = PopupView.margin
        let visible = anchor.visibleFrame
        var x = anchor.point.x - margin
        var y = anchor.growsUp ? anchor.point.y - margin : anchor.point.y + margin - size.height
        // 画面からはみ出す分だけ内側へ寄せる（透明な余白ははみ出してよい）
        x = min(x, visible.maxX - size.width + margin)
        x = max(x, visible.minX - margin)
        y = max(y, visible.minY - margin)
        y = min(y, visible.maxY - size.height + margin)
        return NSPoint(x: x, y: y)
    }
}

@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    private let panel = PopupPanel()
    private let hosting: NSHostingController<PopupView>
    private let vm: PopupViewModel
    private var keyMonitor: Any?

    /// 下に開けるかどうかの判定に使う、ポップアップの高さの目安
    private static let expectedHeight: CGFloat = 460

    init(vm: PopupViewModel) {
        self.vm = vm
        hosting = NSHostingController(rootView: PopupView(vm: vm))
        // 内容（行数・アクションメニューの開閉）に合わせてウインドウの大きさを変える
        hosting.sizingOptions = .preferredContentSize
        super.init()
        panel.delegate = self
        panel.contentViewController = hosting
        vm.close = { [weak self] paste in
            self?.hide()
            if paste { ActionExecutor.pasteIntoFrontmostApp() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        vm.prepare()
        panel.anchor = anchorNearCaret()
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.vm.handleKey(event) ? nil : event
        }
    }

    #if DEBUG
    /// 開発用: 画面収録権限なしでポップアップの見た目を PNG に書き出す
    func writeSnapshot(to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    /// テキストキャレットの右下に開く。キャレットが取れないアプリではマウスカーソルの位置。
    /// 下に十分な余白がなければ上に開く。
    private func anchorNearCaret() -> PopupPanel.Anchor {
        let caret = CaretLocator.caretRect()
        let mouse = NSEvent.mouseLocation
        let below = caret.map { NSPoint(x: $0.minX, y: $0.minY - 4) } ?? NSPoint(x: mouse.x + 2, y: mouse.y - 4)
        let above = caret.map { NSPoint(x: $0.minX, y: $0.maxY + 4) } ?? NSPoint(x: mouse.x + 2, y: mouse.y + 4)

        let screen = NSScreen.screens.first { $0.frame.contains(below) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let roomBelow = below.y - visible.minY
        let roomAbove = visible.maxY - above.y
        let growsUp = roomBelow < Self.expectedHeight && roomAbove > roomBelow
        return PopupPanel.Anchor(point: growsUp ? above : below, growsUp: growsUp, visibleFrame: visible)
    }

    // フォーカスが外れたら閉じる
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// Accessibility API で前面アプリのテキストキャレット位置を取る
enum CaretLocator {
    /// キャレット（選択範囲）の画面上の矩形（Cocoa 座標）。権限がない・対応していないアプリでは nil。
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect != .zero else { return nil }

        // AX はメイン画面の左上が原点。Cocoa の左下原点に直す。
        guard let primary = NSScreen.screens.first else { return nil }
        let height = max(rect.height, 1)
        let flipped = NSRect(x: rect.minX, y: primary.frame.maxY - rect.minY - height, width: rect.width, height: height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped.insetBy(dx: -2, dy: -2)) }) else { return nil }
        return flipped
    }
}
