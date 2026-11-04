import Foundation
import SQLite3
import Testing
@testable import ClingClingCore

struct PinFolderTests {
    func make(_ content: String, at date: Date = Date(), retention: Retention = .normal) -> ClipItem {
        ClipItem(createdAt: date, content: content, contentHash: ContentHash.sha256(content), contentType: .text,
                 source: .unknown, sensitivity: .normal, retention: retention, externalAllowed: true,
                 expiresAt: retention == .temporary ? date.addingTimeInterval(300) : nil, reasons: [])
    }

    func item(_ store: ClipStore, _ content: String) throws -> ClipItem {
        let items = try store.recent()
        return try #require(items.first { $0.content == content })
    }

    @Test func normalizesNames() {
        #expect(PinFolders.normalizedTitle("  社内\nWiki\t") == "社内 Wiki")
        #expect(PinFolders.normalizedTitle(" \n ") == nil)
        #expect(PinFolders.normalizedFolder(String(repeating: "あ", count: 60))?.count == PinFolders.maxFolderLength)
    }

    @Test func titleIsSavedAndPinsTheItem() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("https://example.com/very/long/path"))
        let saved = try item(store, "https://example.com/very/long/path")
        try store.setTitle(saved.id, " 社内 Wiki ")

        let titled = try item(store, saved.content)
        #expect(titled.title == "社内 Wiki")
        #expect(titled.isPinned)

        // 空にすると別名だけ外れ、ピン留めは残る
        try store.setTitle(saved.id, "")
        let cleared = try item(store, saved.content)
        #expect(cleared.title == nil)
        #expect(cleared.isPinned)
    }

    @Test func titleSurvivesRecopy() throws {
        let store = try ClipStore(path: nil)
        let now = Date()
        try store.save(make("memo", at: now))
        try store.setTitle(try item(store, "memo").id, "メモ")
        try store.save(make("memo", at: now.addingTimeInterval(10)))
        let recopied = try item(store, "memo")
        #expect(recopied.title == "メモ")
        #expect(recopied.copyCount == 2)
    }

    @Test func folderPinsAndUnpinningLeavesTheFolder() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("a"))
        let a = try item(store, "a")
        try store.setFolder(a.id, "仕事")
        #expect(try item(store, "a").folder == "仕事")
        #expect(try item(store, "a").isPinned)
        #expect(try store.folders() == ["仕事"])

        try store.setTitle(a.id, "A")
        try store.setPinned(a.id, false)
        let unpinned = try item(store, "a")
        #expect(unpinned.folder == nil)
        #expect(unpinned.title == "A")
        #expect(try store.folders().isEmpty)
    }

    @Test func reusesExistingFolderIgnoringWidthAndKana() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("a"))
        try store.save(make("b"))
        try store.setFolder(try item(store, "a").id, "Work")
        try store.setFolder(try item(store, "b").id, "ｗｏｒｋ")
        #expect(try store.folders() == ["Work"])
    }

    @Test func renameAndRemoveFolder() throws {
        let store = try ClipStore(path: nil)
        for content in ["a", "b", "c"] { try store.save(make(content)) }
        try store.setFolder(try item(store, "a").id, "仕事")
        try store.setFolder(try item(store, "b").id, "仕事")
        try store.setFolder(try item(store, "c").id, "趣味")

        // 既にある名前に変えると 1 つにまとまる
        #expect(try store.renameFolder("趣味", to: "仕事") == "仕事")
        #expect(try store.folders() == ["仕事"])
        #expect(try store.renameFolder("仕事", to: "  ") == nil)

        try store.removeFolder("仕事")
        #expect(try store.folders().isEmpty)
        // 中の Item はピン留めのまま
        #expect(try store.recent(pinnedOnly: true).count == 3)
    }

    @Test func temporaryItemsCannotBeNamedOrFiled() throws {
        let store = try ClipStore(path: nil)
        let secret = make("one-time secret", retention: .temporary)
        try store.save(secret)
        try store.setTitle(secret.id, "秘密")
        try store.setFolder(secret.id, "仕事")
        let kept = try item(store, "one-time secret")
        #expect(kept.title == nil)
        #expect(kept.folder == nil)
        #expect(!kept.isPinned)
        #expect(try store.folders().isEmpty)
    }

    @Test func searchFindsTitleAndFolder() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("https://example.com/a1b2"))
        try store.save(make("ssh deploy@10.0.0.1"))
        try store.setTitle(try item(store, "https://example.com/a1b2").id, "社内 Wiki")
        try store.setFolder(try item(store, "ssh deploy@10.0.0.1").id, "サーバー")
        #expect(try store.recent(query: "wiki").map(\.content) == ["https://example.com/a1b2"])
        #expect(try store.recent(query: "さーばー").map(\.content) == ["ssh deploy@10.0.0.1"])

        // 別名を変えたら、前の別名では見つからない
        try store.setTitle(try item(store, "https://example.com/a1b2").id, "ドキュメント")
        #expect(try store.recent(query: "wiki").isEmpty)
    }

    @Test func groupsFoldersByNameThenLooseItems() {
        var items = ["a", "b", "c", "d"].map { make($0, retention: .pinned) }
        items[0].folder = "フォルダ 10"
        items[2].folder = "フォルダ 2"
        items[3].folder = "フォルダ 10"
        let groups = PinFolders.group(items)
        #expect(groups.map { $0.folder } == ["フォルダ 2", "フォルダ 10", nil])
        #expect(groups.map { $0.items.map(\.content) } == [["c"], ["a", "d"], ["b"]])
    }

    @Test func filtersFoldersByQuery() {
        let folders = ["仕事", "趣味", "Work Docs"]
        #expect(PinFolders.filter(folders, query: "") == folders)
        #expect(PinFolders.filter(folders, query: "docs") == ["Work Docs"])
        #expect(PinFolders.filter(folders, query: "しゅみ") == [])
        #expect(PinFolders.existing("ｗｏｒｋ ｄｏｃｓ", in: folders) == "Work Docs")
    }

    /// 別名とフォルダの列が無い前の版の DB に、列を足して読める
    @Test func migratesDatabaseWithoutTitleAndFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClingCling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clingcling.sqlite")

        var db: OpaquePointer?
        let opened = sqlite3_open(url.path, &db)
        try #require(opened == SQLITE_OK)
        let created = sqlite3_exec(db, """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY, created_at REAL NOT NULL, last_copied_at REAL NOT NULL, content TEXT NOT NULL,
                content_hash TEXT NOT NULL UNIQUE, content_type TEXT NOT NULL, source_bundle_id TEXT, source_name TEXT,
                sensitivity TEXT NOT NULL, retention TEXT NOT NULL, copy_count INTEGER NOT NULL DEFAULT 1,
                external_allowed INTEGER NOT NULL, reasons TEXT NOT NULL DEFAULT '', image_file TEXT,
                image_width INTEGER, image_height INTEGER, image_text TEXT
            );
            INSERT INTO clips (id, created_at, last_copied_at, content, content_hash, content_type, sensitivity,
                retention, external_allowed)
            VALUES ('\(UUID().uuidString)', 0, 0, 'old', 'hash-old', 'text', 'normal', 'pinned', 1);
            """, nil, nil, nil)
        sqlite3_close(db)
        try #require(created == SQLITE_OK)

        let store = try ClipStore(path: url)
        let old = try item(store, "old")
        #expect(old.title == nil)
        #expect(old.folder == nil)
        try store.setTitle(old.id, "古い")
        try store.setFolder(old.id, "保管")
        #expect(try item(store, "old").title == "古い")
        #expect(try store.folders() == ["保管"])
    }
}
