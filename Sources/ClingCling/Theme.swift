import AppKit
import SwiftUI

/// ClingCling の色。すべてロゴから採っている。
/// - コーラル: 2 つの輪。ブランドの主役で、操作できる要素の強調にも使う
/// - シアン: 輪の接点の小さな光。面には塗らず、「一点だけ光る」場所に限って使う
/// - ネイビー: ロゴタイプ。ダークモードの面の色味にする
enum Theme {
    static let brandCoral = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x84 / 255)
    static let brandSpark = Color(red: 0x00 / 255, green: 0xD8 / 255, blue: 0xFE / 255)
    private static let navy = NSColor(srgbRed: 0x00 / 255, green: 0x1A / 255, blue: 0x42 / 255, alpha: 1)

    /// 白い文字を載せる面（選択中の行、主要なボタン）。
    /// ロゴのコーラルは白文字とのコントラストが足りないので、同じ色相で濃くしてある（白文字で 4.7:1）。
    static let accent = Color(red: 0xD9 / 255, green: 0x2E / 255, blue: 0x54 / 255)
    /// 文字やアイコン、スイッチの強調色。ダークでは濃い色が沈むのでロゴのコーラルにする。
    static let tint = dynamic(light: NSColor(accent), dark: NSColor(brandCoral))

    /// デスクトップのぼかしの上に重ねる色味
    static let backdropTint = dynamic(light: NSColor(white: 1, alpha: 0.5), dark: navy.withAlphaComponent(0.72))
    /// ポップアップの material に重ねる色味。設定ウインドウと同じ系統の面に見せる
    static let popupTint = dynamic(light: NSColor(white: 1, alpha: 0.12), dark: navy.withAlphaComponent(0.28))
    /// macOS 26 より前のパネルの塗り（26 以降は Liquid Glass が担う）
    static let panelFill = dynamic(light: NSColor(white: 1, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.06))
    /// ガラスの縁
    static let rim = dynamic(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.14))
    /// 設定のカード。背景の光の上でも文字のコントラストが保てる濃さにする
    static let cardFill = dynamic(light: NSColor(white: 1, alpha: 0.78), dark: NSColor(white: 1, alpha: 0.06))
    static let cardStroke = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))
    /// サイドバーの選択中の項目とホバー
    static let selection = dynamic(light: NSColor(white: 1, alpha: 0.75), dark: NSColor(white: 1, alpha: 0.14))
    static let hover = dynamic(light: NSColor(white: 1, alpha: 0.4), dark: NSColor(white: 1, alpha: 0.06))
    static let selectionShadow = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 0, alpha: 0.3))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// 設定ウインドウの背景。デスクトップのぼかしに、ロゴの形をなぞった光を重ねる。
/// 右上で重なる 2 つのコーラルの輪と、その接点に灯るシアンの光。
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            BehindWindowBlur()
            Theme.backdropTint
            GeometryReader { proxy in
                // 幅だけを基準に置く。リサイズしても輪の交点とシアンの光がずれない
                let width = proxy.size.width
                ZStack {
                    ring(diameter: width * 0.42).position(x: width * 0.68, y: width * -0.114)
                    ring(diameter: width * 0.42).position(x: width * 0.98, y: width * 0.012)
                    Circle()
                        .fill(Theme.brandSpark)
                        .frame(width: width * 0.07, height: width * 0.07)
                        .blur(radius: 26)
                        .position(x: width * 0.78, y: width * 0.072)
                }
                .opacity(colorScheme == .dark ? 0.34 : 0.3)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func ring(diameter: CGFloat) -> some View {
        Circle()
            .stroke(Theme.brandCoral, lineWidth: diameter * 0.2)
            .frame(width: diameter, height: diameter)
            .blur(radius: 44)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// 浮いたガラスのパネル。macOS 26 以降は Liquid Glass、それより前は material で代用する。
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .background(Theme.panelFill, in: shape)
                .overlay(shape.strokeBorder(Theme.rim, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}

/// ロゴのマーク（scripts/make-icons.swift で生成）。`swift run` では無いので SF Symbol で代用する。
struct AppLogo: View {
    var height: CGFloat

    private static let image = NSImage(named: "Logo")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        } else {
            Image(systemName: "infinity")
                .font(.system(size: height * 0.8, weight: .semibold))
                .foregroundStyle(Theme.brandCoral)
                .frame(height: height)
        }
    }
}
