import Foundation
import SQLite3
import Testing
@testable import ClingClingCore

/// 画像から読み取った文字（OCR）の扱い
struct ImageTextGateTests {
    let gate = PrivacyGate()
    let settings = PrivacySettings()
    let preview = SourceApp(bundleID: "com.apple.Preview", name: "Preview")
    let png = Data([0x89, 0x50, 0x4E, 0x47, 7, 7, 7])

    func capture(_ text: String, settings: PrivacySettings? = nil) throws -> ClipItem {
        let input = CaptureInput(image: ImageCapture(png: png, width: 800, height: 600, recognizedText: text),
                                 pasteboardTypes: ["public.png"], source: preview)
        let decision = gate.evaluate(input, settings: settings ?? self.settings)
        guard case .capture(let item) = decision else { return try #require(nil as ClipItem?) }
        return item
    }

    @Test func keepsRecognizedTextButStaysLocalOnly() throws {
        let item = try capture("  来週の会議のメモ\nAgenda: 予算の確認\n")
        #expect(item.contentType == .image)
        #expect(item.sensitivity == .normal)
        #expect(item.retention == .normal)
        // OCR の読み違いや文字以外の中身は検査できないので、外部送信は不可のまま
        #expect(item.externalAllowed == false)
        #expect(item.recognizedText == "来週の会議のメモ\nAgenda: 予算の確認")
        #expect(item.displayContent == "来週の会議のメモ\nAgenda: 予算の確認")
        #expect(item.reasons.contains("Image: text recognized"))
        // 本文はラベルのまま（貼り付けは画像として行う）
        #expect(item.content.contains("800"))
    }

    @Test func imagesWithoutTextAreNotInspected() throws {
        let item = try capture(" \n ")
        #expect(item.recognizedText == nil)
        #expect(item.displayContent == item.content)
        #expect(item.reasons == ["Image: content not inspected"])
    }

    // スクリーンショットに写った API キーは、テキストと同じくディスクに書かない
    @Test func secretsInImagesAreTemporary() throws {
        let item = try capture("export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE")
        #expect(item.sensitivity == .secret)
        #expect(item.retention == .temporary)
        #expect(item.expiresAt != nil)
        #expect(item.externalAllowed == false)
    }

    @Test func secretsInImagesFollowTheSetting() throws {
        var s = settings
        s.neverSavePasswords = false
        let item = try capture("AKIAIOSFODNN7EXAMPLE", settings: s)
        #expect(item.sensitivity == .secret)
        #expect(item.retention == .normal)
    }

    @Test func verificationCodesInImagesAreTemporary() throws {
        let item = try capture("824913")
        #expect(item.sensitivity == .secret)
        #expect(item.retention == .temporary)
        // 一時 Item の画像は、アプリ側でサムネイルもプレビューも出さない（isFullyMasked で判定）
        #expect(item.isFullyMasked)
    }

    @Test func secretTextIsMaskedOnScreen() throws {
        let item = try capture("AKIAIOSFODNN7EXAMPLE")
        let detector = SecretDetector()
        #expect(item.isFullyMasked)
        #expect(!item.rowText(detector: detector).contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!item.fullText(limit: 1_000, detector: detector).contains("AKIAIOSFODNN7EXAMPLE"))
    }
}

struct ImageTextStoreTests {
    func makeImage(_ png: Data, text: String = "", retention: Retention = .normal, at date: Date = Date()) -> ClipItem {
        let hash = ContentHash.sha256(png)
        let temporary = retention == .temporary
        return ClipItem(createdAt: date, content: "画像 2×2", contentHash: hash, contentType: .image, source: .unknown,
                        sensitivity: temporary ? .secret : .normal, retention: retention, externalAllowed: false,
                        expiresAt: temporary ? date.addingTimeInterval(300) : nil, reasons: [],
                        image: ClipImage(fileName: hash + ".png", width: 2, height: 2, text: text))
    }

    @Test func recognizedTextRoundTripsAndIsSearchable() throws {
        let store = try ClipStore(path: nil)
        let png = Data([1, 1, 2, 3])
        try store.save(makeImage(png, text: "請求書 No.2048"), imageData: png)

        let item = try #require(try store.recent().first)
        #expect(item.recognizedText == "請求書 No.2048")
        #expect(try store.recent(query: "請求書").count == 1)
        #expect(try store.recent(query: "no.2048").count == 1)
        // ラベルでも見つかる
        #expect(try store.recent(query: "画像").count == 1)
    }

    // 文字を読み取る前に保存した画像も、コピーし直せば文字が付く
    @Test func copyingAgainUpdatesRecognizedText() throws {
        let store = try ClipStore(path: nil)
        let png = Data([4, 5, 6])
        try store.save(makeImage(png), imageData: png)
        #expect(try store.recent(query: "hello").isEmpty)

        try store.save(makeImage(png, text: "Hello"), imageData: png)
        let item = try #require(try store.recent().first)
        #expect(try store.recent().count == 1)
        #expect(item.recognizedText == "Hello")
        #expect(try store.recent(query: "hello").count == 1)
    }

    @Test func temporaryImagesStayInMemory() throws {
        let store = try ClipStore(path: nil)
        let now = Date()
        let png = Data([9, 8, 7])
        let item = try store.save(makeImage(png, text: "AKIAIOSFODNN7EXAMPLE", retention: .temporary, at: now),
                                  imageData: png)

        #expect(store.imageURL(for: item) == nil)
        #expect(store.imageData(for: item) == png)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path)
        #expect(files.isEmpty)

        try store.prune(now: now.addingTimeInterval(301), retentionDays: 30, historyLimit: 100)
        #expect(store.imageData(for: item) == nil)
        #expect(try store.recent(now: now.addingTimeInterval(301)).isEmpty)
    }

    // 以前ディスクに保存した画像に Secret が写っていたと分かったら、ディスクから消して一時 Item に置き換える
    @Test func savedImageIsReplacedWhenItTurnsOutToBeSecret() throws {
        let store = try ClipStore(path: nil)
        let png = Data([3, 1, 4, 1, 5])
        let saved = try store.save(makeImage(png), imageData: png)
        let file = try #require(store.imageURL(for: saved))

        let secret = try store.save(makeImage(png, text: "AKIAIOSFODNN7EXAMPLE", retention: .temporary), imageData: png)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try store.recent().map(\.id) == [secret.id])
        #expect(store.imageData(for: secret) == png)
    }

    // OCR の列が無い古い履歴も開ける
    @Test func migratesHistoryWithoutTextColumn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClingCling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("clingcling.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        let legacy = """
        CREATE TABLE clips (
            id TEXT PRIMARY KEY, created_at REAL NOT NULL, last_copied_at REAL NOT NULL, content TEXT NOT NULL,
            content_hash TEXT NOT NULL UNIQUE, content_type TEXT NOT NULL, source_bundle_id TEXT, source_name TEXT,
            sensitivity TEXT NOT NULL, retention TEXT NOT NULL, copy_count INTEGER NOT NULL DEFAULT 1,
            external_allowed INTEGER NOT NULL, reasons TEXT NOT NULL DEFAULT '',
            image_file TEXT, image_width INTEGER, image_height INTEGER
        );
        INSERT INTO clips VALUES ('\(UUID().uuidString)', 0, 0, '画像 2×2', 'old', 'image', NULL, NULL,
            'normal', 'normal', 1, 0, '', 'old.png', 2, 2);
        """
        #expect(sqlite3_exec(db, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try ClipStore(path: path)
        let old = try #require(try store.recent().first)
        #expect(old.image?.fileName == "old.png")
        #expect(old.recognizedText == nil)

        let png = Data([2, 7, 1, 8])
        try store.save(makeImage(png, text: "migrated"), imageData: png)
        #expect(try store.recent(query: "migrated").count == 1)
    }
}

struct ImageTextActionTests {
    let ranker = ActionRanker()

    func image(text: String) -> ClipItem {
        ClipItem(createdAt: Date(), content: "画像 2×2", contentHash: "h", contentType: .image, source: .unknown,
                 sensitivity: .normal, retention: .normal, externalAllowed: false, expiresAt: nil, reasons: [],
                 image: ClipImage(fileName: "h.png", width: 2, height: 2, text: text))
    }

    @Test func pasteTextIsOfferedOnlyWhenTextWasRecognized() {
        #expect(ranker.rank(image(text: "Hello"), stats: nil) == [.copy, .pasteText, .saveImage])
        #expect(ranker.rank(image(text: ""), stats: nil) == [.copy, .saveImage])
    }

    @Test func pasteTextStaysOnTheMac() {
        #expect(!SmartAction.pasteText.sendsContentExternally)
        #expect(!SmartAction.pasteText.needsConfirmation(for: "rm -rf /"))
    }
}
