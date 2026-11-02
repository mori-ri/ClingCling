import AppKit
import SwiftUI

/// 画像の行にマウスを載せたときに、ポップアップの横へ出す拡大プレビュー。
///
/// ポップアップ本体のウインドウを広げるとカーソルの下の行がずれてプレビューが点滅するので、
/// マウスを素通しする別のパネル（ポップアップの子ウインドウ）に出す。
final class ImagePreviewPanel: NSPanel {
    private let hosting = NSHostingView(rootView: ImagePreviewView(image: NSImage(), caption: ""))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 行のホバーを奪わないようにマウスは素通しする
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `rowFrame`（"popup" 座標系）の行の横に出す。右に入らなければ左に出す。
    func show(image: NSImage, caption: String, rowFrame: CGRect, beside parent: NSWindow) {
        hosting.rootView = ImagePreviewView(image: image, caption: caption)
        let size = hosting.fittingSize
        let margin = ImagePreviewView.margin
        let host = parent.frame
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? host

        // ポップアップのパネル（影の余白を除いた部分）の左右の端
        let panelLeft = host.minX + PopupView.margin
        let panelRight = panelLeft + PopupView.panelWidth
        let gap: CGFloat = 6
        let rightX = panelRight + gap - margin
        let leftX = panelLeft - gap - size.width + margin
        let fitsRight = rightX + size.width - margin <= visible.maxX
        let fitsLeft = leftX + margin >= visible.minX
        var x = fitsRight || !fitsLeft ? rightX : leftX
        x = min(max(x, visible.minX - margin), visible.maxX - size.width + margin)

        // 上端を行の上端に揃える（"popup" 座標系は左上原点）。画面からはみ出す分は内側へ寄せる。
        let rowTop = host.maxY - rowFrame.minY
        var y = rowTop + margin - size.height
        y = max(y, visible.minY - margin)
        y = min(y, visible.maxY - size.height + margin)

        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

struct ImagePreviewView: View {
    /// 影を描く余白
    static let margin: CGFloat = 18
    /// 画像の長辺の最大表示サイズ（pt）
    static let maxSide: CGFloat = 320

    let image: NSImage
    let caption: String

    var body: some View {
        let size = Self.displaySize(for: image.size)
        VStack(spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .popupSurface(cornerRadius: 10)
        .padding(Self.margin)
        .fixedSize()
    }

    /// 縦横比を保って `maxSide` に収める。小さい画像は 2 倍まで拡大する。
    static func displaySize(for pixels: NSSize) -> NSSize {
        guard pixels.width > 0, pixels.height > 0 else { return NSSize(width: maxSide, height: maxSide) }
        let scale = min(maxSide / pixels.width, maxSide / pixels.height, 2)
        return NSSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
    }
}
