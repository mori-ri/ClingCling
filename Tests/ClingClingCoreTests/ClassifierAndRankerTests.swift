import Foundation
import Testing
@testable import ClingClingCore

struct ClassifierTests {
    let classifier = ContentClassifier()

    @Test(arguments: [
        ("https://github.com/typesafe-ai/jev", ContentType.url),
        ("www.apple.com", .url),
        ("mori@example.com", .email),
        ("AccessDeniedException", .error),
        ("Traceback (most recent call last):\n  File \"a.py\", line 1, in <module>\nKeyError: 'x'", .error),
        ("zsh: command not found: foo", .error),
        ("aws logs tail /aws/lambda/my-fn --follow", .command),
        ("$ git status", .command),
        ("NODE_ENV=production npm run build", .command),
        ("{\"a\": 1, \"b\": [true, null]}", .json),
        ("func hello() -> String {\n    return \"hi\"\n}", .code),
        ("〒100-0001 東京都千代田区千代田1-1", .address),
        ("824913", .verificationCode),
        ("来週の会議についてですが、少し時間をずらせますか？", .text),
        ("   ", .other),
    ])
    func classifies(_ input: String, _ expected: ContentType) {
        #expect(classifier.classify(input) == expected)
    }

    @Test func phoneNumberIsNotAddress() {
        #expect(classifier.classify("03-1234-5678") != .address)
    }
}

struct ActionRankerTests {
    let ranker = ActionRanker()

    func item(_ type: ContentType, external: Bool = true, app: String = "com.apple.Terminal") -> ClipItem {
        ClipItem(createdAt: Date(), content: "x", contentHash: "h", contentType: type,
                 source: SourceApp(bundleID: app, name: nil), sensitivity: external ? .normal : .secret,
                 retention: .normal, externalAllowed: external, expiresAt: nil, reasons: [])
    }

    struct FakeStats: ActionStatsProvider {
        var app: [SmartAction: Int] = [:]
        var type: [SmartAction: Int] = [:]
        func actionCounts(contentType: ContentType, sourceKey: String?) -> [SmartAction: Int] {
            sourceKey == nil ? type : app
        }
    }

    // Wow Moment ケース1, 2
    @Test func defaultOrders() {
        #expect(ranker.rank(item(.error), stats: nil) == [.explain, .search, .copy])
        #expect(ranker.rank(item(.url), stats: nil) == [.open, .markdown, .copy])
        #expect(ranker.rank(item(.text), stats: nil) == [.copy, .polish, .shorten])
    }

    @Test func localOnlyHidesExternalActions() {
        #expect(ranker.rank(item(.error, external: false), stats: nil) == [.copy])
        #expect(ranker.rank(item(.text, external: false), stats: nil) == [.copy])
        #expect(ranker.rank(item(.url, external: false), stats: nil) == [.open, .markdown, .copy])
    }

    @Test func emailFromMailPrefersNewMail() {
        #expect(ranker.rank(item(.email, app: "com.apple.mail"), stats: nil).first == .newMail)
        #expect(ranker.rank(item(.email, app: "com.microsoft.VSCode"), stats: nil).first == .copy)
    }

    // 仕様 §10: Terminal のエラーで Search ばかり選ぶと Search が先頭に来る
    @Test func learnsFromUsage() {
        let stats = FakeStats(app: [.search: 5], type: [.search: 5])
        #expect(ranker.rank(item(.error), stats: stats) == [.search, .explain, .copy])
    }

    @Test func singleSelectionDoesNotFlipOrder() {
        let stats = FakeStats(app: [.copy: 1], type: [:])
        #expect(ranker.rank(item(.url), stats: stats).first == .open)
    }
}

struct ClipStoreTests {
    func make(_ text: String, retention: Retention = .normal, at date: Date = Date()) -> ClipItem {
        ClipItem(createdAt: date, content: text, contentHash: ContentHash.sha256(text), contentType: .text,
                 source: .unknown, sensitivity: .normal, retention: retention, externalAllowed: true,
                 expiresAt: retention == .temporary ? date.addingTimeInterval(300) : nil, reasons: [])
    }

    @Test func deduplicatesByHash() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("hello"))
        let second = try store.save(make("hello"))
        #expect(second.copyCount == 2)
        #expect(try store.recent().count == 1)
    }

    @Test func temporaryItemsStayInMemoryAndExpire() throws {
        let store = try ClipStore(path: nil)
        let now = Date()
        try store.save(make("824913", retention: .temporary, at: now))
        #expect(try store.recent(now: now).count == 1)
        #expect(try store.recent(now: now.addingTimeInterval(301)).isEmpty)
        try store.prune(now: now.addingTimeInterval(301), retentionDays: 30, historyLimit: 100)
        #expect(try store.recent(now: now).isEmpty)
    }

    @Test func pruneKeepsPinned() throws {
        let store = try ClipStore(path: nil)
        let old = Date().addingTimeInterval(-40 * 86_400)
        let pinned = try store.save(make("keep", at: old))
        try store.setPinned(pinned.id, true)
        try store.save(make("drop", at: old))
        try store.prune(retentionDays: 30, historyLimit: 100)
        #expect(try store.recent().map(\.content) == ["keep"])
    }

    @Test func searchEscapesWildcards() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("100% done"))
        try store.save(make("1000 items"))
        #expect(try store.recent(query: "0%").map(\.content) == ["100% done"])
    }

    @Test func recordsFirstActionRate() throws {
        let store = try ClipStore(path: nil)
        let item = make("x")
        try store.recordAction(.copy, for: item, position: 0)
        try store.recordAction(.polish, for: item, position: 1)
        #expect(store.firstActionSelectionRate().rate == 0.5)
        #expect(store.actionCounts(contentType: .text, sourceKey: "unknown")[.copy] == 1)
    }

    func makeImage(_ png: Data, at date: Date = Date()) -> ClipItem {
        let hash = ContentHash.sha256(png)
        return ClipItem(createdAt: date, content: "画像 2×2", contentHash: hash, contentType: .image, source: .unknown,
                        sensitivity: .normal, retention: .normal, externalAllowed: false, expiresAt: nil, reasons: [],
                        image: ClipImage(fileName: hash + ".png", width: 2, height: 2))
    }

    @Test func imagesRoundTripAndFilesFollowRows() throws {
        let store = try ClipStore(path: nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])
        let saved = try store.save(makeImage(png), imageData: png)
        try store.save(makeImage(png), imageData: png)

        let item = try #require(try store.recent().first)
        #expect(try store.recent().count == 1)
        #expect(item.copyCount == 2)
        #expect(item.image == saved.image)
        #expect(store.imageData(for: item) == png)
        #expect(try store.recent(query: "画像").count == 1)

        let file = try #require(store.imageURL(for: item))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        try store.delete(item.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func prunedImagesAreRemovedFromDisk() throws {
        let store = try ClipStore(path: nil)
        let old = Date().addingTimeInterval(-40 * 86_400)
        let png = Data([1, 2, 3, 4])
        let item = try store.save(makeImage(png, at: old), imageData: png)
        let file = try #require(store.imageURL(for: item))
        try store.prune(retentionDays: 30, historyLimit: 100)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
