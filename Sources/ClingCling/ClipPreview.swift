import AppKit
import ClingClingCore
import SwiftUI

/// 行にマウスを載せたときに、ポップアップの横へ出すプレビュー。本文の全文（画像なら拡大）と、
/// いつ・どのアプリでコピーしたかを出す。
///
/// ポップアップ本体のウインドウを広げるとカーソルの下の行がずれてプレビューが点滅するので、
/// 別のパネル（ポップアップの子ウインドウ）に出す。長い本文をスクロールできるようマウスは受けるが、
/// キーにはならないのでポップアップは閉じない。ポップアップの行に重ならないよう、余白を持たせず影はウインドウに付ける。
final class ClipPreviewPanel: NSPanel {
    /// マウスがカードに入った・出た
    var onHover: (Bool) -> Void = { _ in }

    private let hosting = NSHostingView(rootView: ClipPreviewView.empty)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = hosting
        // アプリが前面にないので、SwiftUI の onHover に頼らず常に届く追跡領域を使う
        hosting.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                               owner: self, userInfo: nil))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 今カードに出している Item
    private var shownItem: ClipItem?

    // 閉じた後に届いた「入った」は捨てる。対になる「出た」が届かず、ほかの行のプレビューが出なくなる。
    override func mouseEntered(with event: NSEvent) { if isVisible { onHover(true) } }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    /// `rowFrame`（"popup" 座標系）の行の横に出す。右に入らなければ左に出す。
    /// 同じ Item で行が動いただけなら、本文を作り直さずに位置だけ変える（全文の Secret 検出と組版が重い）。
    func show(_ item: ClipItem, image: @autoclosure () -> NSImage?, rowFrame: CGRect, beside parent: NSWindow) {
        var size = frame.size
        if item != shownItem || !isVisible {
            shownItem = item
            hosting.rootView = ClipPreviewView(image: image(), item: item)
            size = hosting.fittingSize
        }
        let host = parent.frame
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? host

        // ポップアップのパネル（影の余白を除いた部分）の左右の端
        let panelLeft = host.minX + PopupView.margin
        let panelRight = panelLeft + PopupView.panelWidth
        let gap: CGFloat = 6
        let rightX = panelRight + gap
        let leftX = panelLeft - gap - size.width
        var x = rightX + size.width <= visible.maxX || leftX < visible.minX ? rightX : leftX
        x = min(max(x, visible.minX), visible.maxX - size.width)

        // 上端を行の上端に揃える（"popup" 座標系は左上原点）。画面からはみ出す分は内側へ寄せる。
        let rowTop = host.maxY - rowFrame.minY
        let y = min(max(rowTop - size.height, visible.minY), visible.maxY - size.height)

        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
        // 影は描かれた形から作られるので、大きさが変わるたびに作り直す。
        // SwiftUI が新しい内容を描き終えてからにしないと、前のカードの形の影が残る。
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        // 一時 Item（OTP など）の本文を、閉じた後のビューに残さない
        shownItem = nil
        hosting.rootView = .empty
    }
}

struct ClipPreviewView: View {
    /// 本文のカードの幅と、スクロールせずに見える高さ
    private static let textWidth: CGFloat = 340
    private static let maxTextHeight: CGFloat = 360
    /// 画像の長辺の最大表示サイズ（pt）
    private static let maxSide: CGFloat = 320

    /// 画像 Item の画像。読み込めなかったときは本文（ラベル）を出す
    let image: NSImage?
    let id: UUID?
    let text: String
    let monospaced: Bool
    /// いつ・どのアプリでコピーしたか
    let meta: String

    static let empty = ClipPreviewView(image: nil, id: nil, text: "", monospaced: false, meta: "")

    private init(image: NSImage?, id: UUID?, text: String, monospaced: Bool, meta: String) {
        self.image = image
        self.id = id
        self.text = text
        self.monospaced = monospaced
        self.meta = meta
    }

    init(image: NSImage?, item: ClipItem) {
        var parts = [Presentation.meta(item)]
        if image != nil { parts.insert(item.content, at: 0) }
        if item.isFullTextCut(limit: Presentation.fullTextLimit) {
            parts.append(String(localized: "先頭 \(Presentation.fullTextLimit) 文字を表示"))
        }
        self.init(image: image, id: item.id, text: Presentation.fullText(item),
                  monospaced: Presentation.isMonospaced(item.contentType), meta: parts.joined(separator: " · "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                let size = Self.displaySize(for: image.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 別の Item に切り替えたらスクロール位置を先頭に戻す
                .id(id)
                .frame(width: Self.textWidth - 16)
                .frame(maxHeight: Self.maxTextHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // 英語などで長くなっても、本文の幅を超えてカードを広げない
                .frame(maxWidth: Self.textWidth - 16, alignment: .leading)
        }
        .padding(8)
        .popupFill(cornerRadius: 10)
        .fixedSize()
    }

    /// 縦横比を保って `maxSide` に収める。小さい画像は 2 倍まで拡大する。
    static func displaySize(for pixels: NSSize) -> NSSize {
        guard pixels.width > 0, pixels.height > 0 else { return NSSize(width: maxSide, height: maxSide) }
        let scale = min(maxSide / pixels.width, maxSide / pixels.height, 2)
        return NSSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
    }
}
