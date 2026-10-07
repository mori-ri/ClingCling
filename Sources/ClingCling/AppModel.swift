import AppKit
import ClingClingCore

/// アプリ全体の状態。Clipboard 監視 → Privacy Gate → 保存 の流れを束ねる。
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let store: ClipStore
    private let gate = PrivacyGate()
    private let ranker = ActionRanker()
    private var monitor: ClipboardMonitor!
    private var pruneTimer: Timer?

    /// 履歴が変化したら増える（ポップアップの再読み込み用）
    @Published private(set) var revision = 0

    init(settings: AppSettings) throws {
        self.settings = settings
        store = try ClipStore(path: ClipStore.defaultURL())
        monitor = ClipboardMonitor { [weak self] input in self?.capture(input) }
    }

    func start() {
        monitor.start()
        prune()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    private func capture(_ input: CaptureInput) {
        guard !settings.isPaused else { return }
        switch gate.evaluate(input, settings: settings.privacySettings) {
        case .drop:
            // 保存しない。理由もログに残さない（内容の推測につながるため）
            return
        case .capture(let item):
            do {
                try store.save(item, imageData: input.image?.png)
                revision += 1
            } catch {
                NSLog("ClingCling: save failed: \(error)")
            }
        }
    }

    func prune() {
        try? store.prune(retentionDays: settings.retentionDays, historyLimit: settings.historyLimit)
        revision += 1
    }

    // MARK: - Queries

    func items(query: String, pinnedOnly: Bool) -> [ClipItem] {
        (try? store.recent(limit: 200, query: query, pinnedOnly: pinnedOnly)) ?? []
    }

    func actions(for item: ClipItem) -> [SmartAction] {
        ranker.rank(item, stats: store)
    }

    // MARK: - Mutations

    func togglePin(_ item: ClipItem) {
        guard !item.isTemporary else { return }
        try? store.setPinned(item.id, !item.isPinned)
        revision += 1
    }

    func delete(_ item: ClipItem) {
        try? store.delete(item.id)
        revision += 1
    }

    func clearHistory() {
        try? store.clear(keepPinned: true)
        revision += 1
    }

    func recordAction(_ action: SmartAction, item: ClipItem, position: Int) {
        try? store.recordAction(action, for: item, position: position)
    }

    /// クリップボードへ書き戻す。Secret は Concealed marker を付けて他の Clipboard Manager に記録させない。
    /// `transient` は AI へ渡すプロンプトのような一時的な内容（他の Clipboard Manager にも残さない）。
    func writeToPasteboard(_ text: String, concealed: Bool = false, transient: Bool = false, reusing item: ClipItem? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType(PrivacyGate.concealedType))
        }
        if transient {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType(PrivacyGate.transientType))
        }
        monitor.ignoreCurrentChange()
        if let item {
            try? store.touch(item.id)
            revision += 1
        }
    }

    /// Item をクリップボードへ書き戻す（画像は画像として）
    func writeItemToPasteboard(_ item: ClipItem) {
        guard item.isImage else {
            writeToPasteboard(item.content, concealed: item.sensitivity >= .suspicious, reusing: item)
            return
        }
        guard let png = store.imageData(for: item) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        // PNG を読めない古いアプリ向けに TIFF も載せる
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        monitor.ignoreCurrentChange()
        try? store.touch(item.id)
        revision += 1
    }

    // MARK: - Images

    private let thumbnails = NSCache<NSString, NSImage>()

    /// 縮小画像（メモリ上にキャッシュ）。`maxPixelSize` は長辺のピクセル数。
    func thumbnail(for item: ClipItem, maxPixelSize: Int = 96) -> NSImage? {
        guard let image = item.image else { return nil }
        let key = "\(maxPixelSize)/\(image.fileName)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let url = store.imageURL(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let thumbnail = NSImage(cgImage: cg, size: .zero)
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    func imageData(for item: ClipItem) -> Data? {
        store.imageData(for: item)
    }

    typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    /// 一時的にクリップボードを借りる前の内容（テキスト以外も含む）
    func snapshotPasteboard() -> PasteboardSnapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } },
                       uniquingKeysWith: { first, _ in first })
        }
    }

    func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = snapshot.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        monitor.ignoreCurrentChange()
    }
}
