// ロゴ画像からアプリアイコンとメニューバー用テンプレート画像を生成する
//   swift scripts/make-icons.swift Resources/Branding/ClingCling-logo.png Resources/Generated
//
// 出力:
//   AppIcon-1024.png   macOS アイコングリッド（1024 キャンバスに 824 の角丸）にマークを配置
//   MenuBarIcon.png    18pt の 2x（36px）テンプレート画像（黒 + アルファ）
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]),
      let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make-icons.swift <logo.png> <outdir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// ロゴタイプを除いたマーク部分（元画像 1536px 幅基準の座標を比率で指定）
// ロゴは透過 PNG。透明部分にも色データが残っているので、必ずアルファ込みで扱う
let scale = CGFloat(source.width) / 1536
let markRect = CGRect(x: 220 * scale, y: 75 * scale, width: 1085 * scale, height: 702 * scale).integral
guard let mark = source.cropping(to: markRect) else { exit(1) }

func bitmap(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ image: CGImage, _ name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name)")
}

/// アスペクト比を保って rect の中央に収める
func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
    let s = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
    let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

// MARK: App icon

do {
    let size = 1024
    let ctx = bitmap(size)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(mark, in: aspectFit(mark, in: body.insetBy(dx: 90, dy: 90)))
    ctx.restoreGState()

    // 縁取り（白背景のアイコンが明るい Dock でも埋もれないように）
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()

    try write(ctx.makeImage()!, "AppIcon-1024.png")
}

// MARK: Menu bar template

do {
    // マークのアルファをそのまま使い、黒一色のシルエットにする
    let work = 512
    let src = bitmap(work)
    src.interpolationQuality = .high
    src.draw(mark, in: aspectFit(mark, in: CGRect(x: 0, y: 0, width: work, height: work)))
    src.setBlendMode(.sourceIn)
    src.setFillColor(CGColor(gray: 0, alpha: 1))
    src.fill(CGRect(x: 0, y: 0, width: work, height: work))
    let silhouette = src.makeImage()!

    let size = 36
    let ctx = bitmap(size)
    ctx.interpolationQuality = .high
    ctx.draw(silhouette, in: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
    try write(ctx.makeImage()!, "MenuBarIcon.png")
}
