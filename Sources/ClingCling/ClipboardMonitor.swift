import AppKit
import ClingClingCore

/// NSPasteboard の changeCount をポーリングしてコピーを検知する（仕様 §37 Clipboard Capture）。
/// コピーのたびに通知やポップアップは出さない。
@MainActor
final class ClipboardMonitor {
    /// 1 MB を超えるテキストはキャプチャしない
    private static let maxLength = 1_000_000
    /// 30 MB を超える画像データはキャプチャしない
    private static let maxImageBytes = 30_000_000

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let onCapture: (CaptureInput) -> Void

    init(onCapture: @escaping (CaptureInput) -> Void) {
        self.onCapture = onCapture
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// ClingCling 自身が書き込んだ変更はキャプチャしない
    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let app = NSWorkspace.shared.frontmostApplication
        let source = SourceApp(bundleID: app?.bundleIdentifier, name: app?.localizedName)

        // テキストがあればテキストを優先する（表計算のセルなどは画像も一緒に載るため）
        if let text = pasteboard.string(forType: .string) {
            guard text.count <= Self.maxLength else { return }
            onCapture(CaptureInput(text: text, pasteboardTypes: types, source: source))
            return
        }
        // Finder でのファイルコピーはアイコン画像が載るだけなので対象外（ファイルは未対応）
        guard !types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) else { return }
        let png = pasteboard.data(forType: .png)
        guard let data = png ?? pasteboard.data(forType: .tiff), data.count <= Self.maxImageBytes else { return }

        // TIFF → PNG の変換は重いことがあるので裏で行う
        let isPNG = png != nil
        let date = Date()
        let onCapture = onCapture
        Task.detached(priority: .userInitiated) {
            guard let image = Self.makeImage(data, isPNG: isPNG) else { return }
            await MainActor.run {
                onCapture(CaptureInput(image: image, pasteboardTypes: types, source: source, date: date))
            }
        }
    }

    /// 保存用の PNG とピクセルサイズ
    nonisolated static func makeImage(_ data: Data, isPNG: Bool) -> ImageCapture? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        guard let png = isPNG ? data : rep.representation(using: .png, properties: [:]) else { return nil }
        return ImageCapture(png: png, width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
