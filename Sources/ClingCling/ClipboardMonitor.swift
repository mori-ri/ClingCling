import AppKit
import ClingClingCore

/// NSPasteboard の changeCount をポーリングしてコピーを検知する。
/// コピーのたびに通知やポップアップは出さない。
@MainActor
final class ClipboardMonitor {
    /// 1 MB を超えるテキストはキャプチャしない
    private static let maxLength = 1_000_000
    /// 30 MB を超える画像データはキャプチャしない（画像のファイルのサムネイルもこの大きさまで）
    static let maxImageBytes = 30_000_000

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

        // ファイルを先に見る。Finder でのファイルコピーには、ファイル名のテキストとアイコンの画像も載るため。
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            switch copiedFiles() {
            case .files(let paths):
                onCapture(CaptureInput(filePaths: paths, pasteboardTypes: types, source: source))
                return
            case .skip:
                return
            case .noFiles:
                // 受け渡し用の一時ファイルなど。一緒に載っている本文か画像を残す
                break
            }
        }

        // テキストがあればテキストを優先する（表計算のセルなどは画像も一緒に載るため）
        if let text = pasteboard.string(forType: .string) {
            guard text.count <= Self.maxLength else { return }
            onCapture(CaptureInput(text: text, pasteboardTypes: types, source: source))
            return
        }
        let png = pasteboard.data(forType: .png)
        guard let data = png ?? pasteboard.data(forType: .tiff), data.count <= Self.maxImageBytes else { return }

        // TIFF → PNG の変換と文字の読み取り（OCR）は重いことがあるので裏で行う。
        // Privacy Gate は読み取った文字で Secret を判定するので、読み取りが終わってから渡す。
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

    private enum CopiedFilesResult {
        case files([String])
        /// 残すファイルがない（アプリが一時ディレクトリに書き出したファイルだけ、など）
        case noFiles
        /// 読めない・多すぎる。キャプチャしない
        case skip
    }

    /// コピーされたファイルのパス。フォルダ（`.app` などのパッケージを含む）は末尾に `/` を付ける。
    private func copiedFiles() -> CopiedFilesResult {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return .noFiles }
        guard urls.count <= CopiedFiles.maxCount else { return .skip }
        var paths: [String] = []
        for url in urls {
            // Finder はファイル参照 URL（file:///.file/id=…）を載せることがあるので、パスの URL に直す
            let fileURL = (url as NSURL).filePathURL ?? url
            let path = fileURL.path
            guard !path.isEmpty, !path.contains(where: \.isNewline) else { return .skip }
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? fileURL.hasDirectoryPath
            paths.append(isDirectory && path != "/" ? path + "/" : path)
        }
        if paths.allSatisfy(CopiedFiles.isTemporaryLocation) { return .noFiles }
        return .files(paths)
    }

    /// 保存用の PNG とピクセルサイズ、写っている文字（OCR）
    nonisolated static func makeImage(_ data: Data, isPNG: Bool) -> ImageCapture? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        guard let png = isPNG ? data : rep.representation(using: .png, properties: [:]) else { return nil }
        let text = rep.cgImage.map(TextRecognizer.recognizeText(in:)) ?? ""
        return ImageCapture(png: png, width: rep.pixelsWide, height: rep.pixelsHigh, recognizedText: text)
    }
}
