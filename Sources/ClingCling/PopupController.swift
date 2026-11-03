import AppKit
import ApplicationServices
import Combine
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
    /// 行にマウスを載せたときに横へ出すプレビュー
    private let previewPanel = ClipPreviewPanel()
    private var cancellables: Set<AnyCancellable> = []
    private var caretRetry: Task<Void, Never>?

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
        vm.$preview.removeDuplicates().sink { [weak self] preview in
            self?.updatePreview(preview)
        }.store(in: &cancellables)
        previewPanel.onHover = { [weak vm] in vm?.previewHovered = $0 }
    }

    private func updatePreview(_ preview: PopupViewModel.Preview?) {
        guard let preview, panel.isVisible else {
            previewPanel.hide()
            return
        }
        let item = preview.item
        previewPanel.show(item, image: vm.model.thumbnail(for: item, maxPixelSize: 720, readingFiles: true),
                          rowFrame: preview.rowFrame, beside: panel)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        vm.prepare()
        let caret = CaretLocator.caretRect()
        panel.anchor = anchor(near: caret)
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            // 日本語入力の変換中（未確定の文字がある間）は ↩ 確定・↑↓ 候補選択・esc 取り消し・数字を IME に渡す。
            // 先に奪うと ↩ で先頭の履歴が貼り付けられてしまい、日本語で検索できない。
            if let input = self.panel.firstResponder as? NSTextInputClient, input.hasMarkedText() { return event }
            return self.vm.handleKey(event) ? nil : event
        }
        if caret == nil { retryCaret() }
    }

    /// Electron や Chromium は、頼まれるまでアクセシビリティのツリーを作らない。
    /// 初回は作られるまで少しかかるので、いったんマウスの位置に開き、取れたらキャレットの横へ移す。
    private func retryCaret() {
        guard CaretLocator.requestAccessibilityTree() else { return }
        caretRetry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.panel.isVisible,
                  let caret = CaretLocator.caretRect() else { return }
            self.panel.anchor = self.anchor(near: caret)
            self.panel.setFrame(self.panel.frame, display: true)
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
        caretRetry?.cancel()
        caretRetry = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        previewPanel.hide()
        panel.orderOut(nil)
    }

    /// テキストキャレットの右下に開く。キャレットが取れないアプリではマウスカーソルの位置。
    /// 下に十分な余白がなければ上に開く。
    private func anchor(near caret: NSRect?) -> PopupPanel.Anchor {
        let mouse = NSEvent.mouseLocation
        let below = caret.map { NSPoint(x: $0.minX, y: $0.minY - 4) } ?? NSPoint(x: mouse.x + 2, y: mouse.y - 4)
        let above = caret.map { NSPoint(x: $0.minX, y: $0.maxY + 4) } ?? NSPoint(x: mouse.x + 2, y: mouse.y + 4)

        // 基準点がどの画面にも入らない（画面の下端ぎりぎりなど）ときに NSScreen.main へ逃がすと、
        // 別のディスプレイに押し込まれて飛んでしまう。いちばん近い画面を使う。
        let screen = Self.screen(nearest: caret.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse)
        let visible = screen.visibleFrame
        let roomBelow = below.y - visible.minY
        let roomAbove = visible.maxY - above.y
        let growsUp = roomBelow < Self.expectedHeight && roomAbove > roomBelow
        return PopupPanel.Anchor(point: growsUp ? above : below, growsUp: growsUp, visibleFrame: visible)
    }

    private static func screen(nearest point: NSPoint) -> NSScreen {
        let screens = NSScreen.screens
        if let hit = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) { return hit }
        func distance(_ frame: NSRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return dx * dx + dy * dy
        }
        return screens.min { distance($0.frame) < distance($1.frame) } ?? NSScreen.main ?? screens[0]
    }

    // フォーカスが外れたら閉じる
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// Accessibility API で前面アプリのテキストキャレット位置を取る
enum CaretLocator {
    /// キャレットの画面上の矩形（Cocoa 座標）。権限がない・対応していない・値が信用できないときは nil。
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted(), let element = focusedElement(),
              let caret = insertionPointBounds(of: element) else { return nil }

        // アプリによっては、要素の原点・テキスト全体・ウインドウ外などのでたらめな矩形を返す。
        // フォーカス中の要素の枠に収まっていない値は捨ててマウス位置にフォールバックする。
        if let frame = frame(of: element), frame.width > 0, frame.height > 0,
           !frame.insetBy(dx: -8, dy: -8).contains(CGPoint(x: caret.midX, y: caret.midY)) {
            return nil
        }

        // AX はメイン画面の左上が原点。Cocoa の左下原点に直す。
        guard let primary = NSScreen.screens.first else { return nil }
        let height = max(caret.height, 1)
        let flipped = NSRect(x: caret.minX, y: primary.frame.maxY - caret.minY - height, width: caret.width, height: height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped.insetBy(dx: -2, dy: -2)) }) else { return nil }
        return flipped
    }

    /// 前面アプリにアクセシビリティのツリーを作ってもらう。対応していないアプリなら false。
    static func requestAccessibilityTree() -> Bool {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// 前面アプリのフォーカス中の要素。システム全体から引くと別アプリの古い要素が返ることがあるので、
    /// まず前面アプリに直接聞く。
    private static func focusedElement() -> AXUIElement? {
        var candidates: [AXUIElement] = []
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            candidates.append(AXUIElementCreateApplication(pid))
        }
        candidates.append(AXUIElementCreateSystemWide())
        for source in candidates {
            AXUIElementSetMessagingTimeout(source, 0.15)
            if let element: AXUIElement = copy(source, kAXFocusedUIElementAttribute) { return element }
        }
        return nil
    }

    /// 選択範囲の先頭にある挿入位置の矩形（AX 座標）。
    /// 長さ 0 の範囲に幅も高さも 0 を返すアプリが多いので、前後の 1 文字の矩形から求め直す。
    private static func insertionPointBounds(of element: AXUIElement) -> CGRect? {
        guard let rangeValue: AXValue = copy(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 else { return nil }

        if let rect = bounds(of: element, location: range.location, length: 0), rect.height > 0 {
            return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
        }
        // 直後の文字の左端
        if let rect = bounds(of: element, location: range.location, length: 1) {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }
        // 末尾にいるときは直前の文字の右端
        if range.location > 0, let rect = bounds(of: element, location: range.location - 1, length: 1) {
            return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
        }
        return nil
    }

    private static func bounds(of element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        // 1 文字分なのに巨大な矩形（テキスト全体・行全体の箱）や原点そのものは信用しない
        guard rect.origin != .zero, rect.height > 0 || length == 0, rect.height <= 200 else { return nil }
        return rect
    }

    /// 要素の枠（AX 座標）
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = copy(element, kAXPositionAttribute),
              let size: AXValue = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        // AXUIElement / AXValue は CF 型なので as? では判定できない。型 ID で確かめる
        let expected = T.self == AXUIElement.self ? AXUIElementGetTypeID() : AXValueGetTypeID()
        guard CFGetTypeID(value) == expected else { return nil }
        return (value as! T)
    }
}
