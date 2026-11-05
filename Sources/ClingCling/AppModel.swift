import AppKit
import ClingClingCore
import UniformTypeIdentifiers

/// アプリ全体の状態。Clipboard 監視 → Privacy Gate → 保存 の流れを束ねる。
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let store: ClipStore
    /// 新しいバージョンの確認と、お知らせのページのリリースノート
    let updates: UpdateChecker
    /// ポップアップを開くグローバルショートカット
    var hotKey: HotKey?
    private let gate = PrivacyGate()
    private let ranker = ActionRanker()
    private var monitor: ClipboardMonitor!
    private var pruneTimer: Timer?

    /// 履歴が変化したら増える（ポップアップの再読み込み用）
    @Published private(set) var revision = 0

    init(settings: AppSettings) throws {
        self.settings = settings
        store = try ClipStore(path: ClipStore.defaultURL())
        // 0.2.0 が設定に置いていたフォルダの並び順と開閉を DB へ移す
        if let legacy = settings.takeLegacyFolderState() {
            try? store.setFolderOrder(legacy.order)
            for name in legacy.open { try? store.setFolderOpen(name, true) }
        }
        updates = UpdateChecker(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            isEnabled: { settings.checksForUpdates },
            fetchReleases: UpdateChecker.releasesFetcher(url: ProjectLinks.releasesAPI))
        monitor = ClipboardMonitor { [weak self] input in self?.capture(input) }
    }

    func start() {
        monitor.start()
        updates.start()
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

    /// ショートカットを切り替える。登録できなければ今のまま false を返す。
    func applyShortcut(_ shortcut: Shortcut) -> Bool {
        guard hotKey?.register(shortcut) == true else { return false }
        settings.shortcut = shortcut
        return true
    }

    func prune() {
        try? store.prune(retentionDays: settings.retentionDays, historyLimit: settings.historyLimit)
        revision += 1
    }

    // MARK: - Queries

    func items(query: String, pinnedOnly: Bool) -> [ClipItem] {
        (try? store.recent(limit: 200, query: query, pinnedOnly: pinnedOnly)) ?? []
    }

    /// ピン留めのすべてを、設定で決めた並び順に。履歴の新しい 200 件に入らない古いピン留めも、フォルダから探せるように
    func pinnedItems(query: String = "") -> [ClipItem] {
        (try? store.pinned(query: query)) ?? []
    }

    /// ピン留めのフォルダの一覧（設定で決めた順。新しいフォルダは最後）
    func folders() -> [String] {
        (try? store.folders()) ?? []
    }

    /// ポップアップで開いているフォルダ
    func openFolders() -> Set<String> {
        (try? store.openFolders()) ?? []
    }

    /// ポップアップでフォルダを開閉する（次に開いたときも残す）。一覧の中身は変わらないので revision は上げない
    func setFolderOpen(_ name: String, _ open: Bool) {
        try? store.setFolderOpen(name, open)
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

    /// 別名を付ける（付けたらピン留めになる）。空なら別名を外す。付けられなければ理由を返す。
    @discardableResult
    func setTitle(_ item: ClipItem, _ title: String) -> String? {
        guard !item.isTemporary else { return nil }
        if let reason = Self.nameRefusal(PinFolders.normalizedTitle(title)) { return reason }
        try? store.setTitle(item.id, title)
        revision += 1
        return nil
    }

    /// 名前は一覧で伏せずに出るので、Secret を含む名前は付けさせない。`name` は保存する形に整えたもの
    static func nameRefusal(_ name: String?) -> String? {
        guard let name, PinFolders.containsSecret(name) else { return nil }
        return String(localized: "パスワード・API キー・トークンを含む名前は付けられません。")
    }

    /// 本文を書き換える。コピーしたときと同じく Privacy Gate で判定し直す。書き換えられなければ理由を返す。
    func updateContent(_ item: ClipItem, to text: String) -> String? {
        guard item.isContentEditable, text != item.content else { return nil }
        switch gate.evaluateEdit(text, of: item, settings: settings.privacySettings) {
        case .empty:
            return String(localized: "内容を空にはできません。")
        case .notSavable:
            return String(localized: "パスワード・API キー・認証コードを含む内容は保存できません。")
        case .accepted(let edited):
            do {
                switch try store.updateContent(item.id, to: edited) {
                case .updated: break
                case .duplicate: return String(localized: "同じ内容の Item が既にあります。")
                case .unavailable: return String(localized: "この Item は削除されたか、書き換えられなくなりました。")
                }
            } catch {
                return String(localized: "保存できませんでした。")
            }
            revision += 1
            return nil
        }
    }

    /// フォルダに入れる（入れたらピン留めになる）。nil ならフォルダから出す。
    func setFolder(_ item: ClipItem, _ folder: String?) {
        setFolder([item], folder)
    }

    /// まとめてフォルダに入れる・出す
    func setFolder(_ items: [ClipItem], _ folder: String?) {
        for item in items where !item.isTemporary { try? store.setFolder(item.id, folder) }
        revision += 1
    }

    /// フォルダの名前を変える。同じ名前のフォルダがあれば 1 つにまとめる（並び順と開閉は引き継ぐ）。
    /// 変えられなければ理由を返す。
    @discardableResult
    func renameFolder(_ old: String, to new: String) -> String? {
        if let reason = Self.nameRefusal(PinFolders.normalizedFolder(new)) { return reason }
        if (try? store.renameFolder(old, to: new)) != nil { revision += 1 }
        return nil
    }

    /// ピン留めを並べ替える。`items` を `target` の前（nil なら `visible` の最後の後ろ）へ。
    /// `visible` は今見えている一覧（フォルダの中など）。
    func movePinned(_ items: [ClipItem], visible: [ClipItem], before target: ClipItem?) {
        let all = pinnedItems().map(\.id)
        let moved = PinFolders.move(items.map(\.id), in: all, visible: visible.map(\.id), before: target?.id)
        guard moved != all else { return }
        try? store.setPinOrder(moved)
        revision += 1
    }

    /// フォルダを並べ替える。`shown` は画面に並べている順（まだ Item の無いフォルダも含む。それは並び順に残さない）
    func moveFolders(_ folders: [String], in shown: [String], before target: String?) {
        let moved = PinFolders.move(folders, in: shown, visible: shown, before: target)
        guard moved != shown else { return }
        try? store.setFolderOrder(moved)
        revision += 1
    }

    /// フォルダを解除する（中の Item はピン留めのまま。並び順と開閉も忘れる）
    func removeFolder(_ name: String) {
        try? store.removeFolder(name)
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

    /// Item をクリップボードへ書き戻す（画像は画像として、ファイルはファイルとして）。
    /// 画像やファイルが見つからず書けなかったら false（クリップボードは変えない）。
    @discardableResult
    func writeItemToPasteboard(_ item: ClipItem) -> Bool {
        if item.isFile { return writeFilesToPasteboard(item) }
        guard item.isImage else {
            writeToPasteboard(item.content, concealed: item.sensitivity >= .suspicious, reusing: item)
            return true
        }
        guard let png = store.imageData(for: item) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        // PNG を読めない古いアプリ向けに TIFF も載せる
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        // 写っている文字に Secret がある画像は、テキストと同じく他の Clipboard Manager に記録させない
        if item.sensitivity >= .suspicious {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType(PrivacyGate.concealedType))
        }
        monitor.ignoreCurrentChange()
        try? store.touch(item.id)
        revision += 1
        return true
    }

    /// ファイルの参照をクリップボードに載せる。Finder に貼ればファイルのコピー、メールなどに貼れば添付になる。
    /// 移動・削除されたファイルは載せない。
    private func writeFilesToPasteboard(_ item: ClipItem) -> Bool {
        let urls = existingFileURLs(item)
        guard !urls.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        monitor.ignoreCurrentChange()
        try? store.touch(item.id)
        revision += 1
        return true
    }

    /// ファイル Item のうち、今もその場所にあるファイル
    func existingFileURLs(_ item: ClipItem) -> [URL] {
        item.filePaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Images

    private let thumbnails = NSCache<NSString, NSImage>()

    /// 縮小画像（メモリ上にキャッシュ）。`maxPixelSize` は長辺のピクセル数。
    /// 写っている文字に Secret がある画像は、テキストの Secret と同じく肩越しに見られないよう出さない
    /// （行は鍵のアイコン、プレビューはマスクした文字になる）。一時 Item の画像はすべてこれに当たる。
    /// `readingFiles` なら、画像のファイル 1 つの Item でも作る。一覧の行では使わない
    /// （開くたびにファイルを読むと、デスクトップなどのフォルダへのアクセスの確認が出ることがある）。
    func thumbnail(for item: ClipItem, maxPixelSize: Int = 96, readingFiles: Bool = false) -> NSImage? {
        guard !item.isFullyMasked else { return nil }
        let url = item.isImage ? store.imageURL(for: item) : readingFiles ? imageFileURL(item) : nil
        guard let url else { return nil }
        let key = "\(maxPixelSize)/\(url.path)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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

    /// 縮小画像を作る画像のファイル。大きすぎるファイルは、開くたびに読むと重いので作らない。
    private func imageFileURL(_ item: ClipItem) -> URL? {
        guard item.fileKind == .image, let path = item.filePaths.first, item.filePaths.count == 1,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size <= ClipboardMonitor.maxImageBytes
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private let fileIcons = NSCache<NSString, NSImage>()

    /// ファイル Item の行に出す Finder のアイコン。複数のファイルでは nil。
    /// 一覧を開くたびにファイルへ触れると、デスクトップや書類のフォルダへのアクセスの確認が出ることがあるので、
    /// 拡張子から決まる種類のアイコンを使う。アプリだけは本体のアイコンを出す（多くは /Applications にある）。
    func fileIcon(for item: ClipItem) -> NSImage? {
        guard item.isFile, item.filePaths.count == 1, let path = item.filePaths.first else { return nil }
        let key = path as NSString
        if let cached = fileIcons.object(forKey: key) { return cached }
        let icon: NSImage
        if item.fileKind == .application {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if path.hasSuffix("/") && item.fileKind == .folder {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (CopiedFiles.plainPath(path) as NSString).pathExtension
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        fileIcons.setObject(icon, forKey: key)
        return icon
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
