import Foundation
import SQLite3
import Testing
@testable import ClingClingCore

/// ピン留めとフォルダの並び順
struct PinOrderTests {
    func make(_ content: String, at date: Date) -> ClipItem {
        ClipItem(createdAt: date, content: content, contentHash: ContentHash.sha256(content), contentType: .text,
                 source: .unknown, sensitivity: .normal, retention: .normal, externalAllowed: true,
                 expiresAt: nil, reasons: [])
    }

    func id(_ store: ClipStore, _ content: String) throws -> UUID {
        try #require(try store.recent().first { $0.content == content }).id
    }

    @Test func newPinsComeFirstAndOrderSurvivesRecopy() throws {
        let store = try ClipStore(path: nil)
        let now = Date()
        for (i, text) in ["a", "b", "c"].enumerated() { try store.save(make(text, at: now.addingTimeInterval(Double(i)))) }
        try store.setPinned(try id(store, "a"), true)
        try store.setPinned(try id(store, "b"), true)
        try store.setFolder(try id(store, "c"), "仕事")
        #expect(try store.pinned().map(\.content) == ["c", "b", "a"])

        // コピーし直しても並び順は変わらない
        try store.save(make("a", at: now.addingTimeInterval(100)))
        #expect(try store.pinned().map(\.content) == ["c", "b", "a"])

        // 既にピン留めなら、別名やフォルダを付けても並び順は変わらない
        try store.setTitle(try id(store, "a"), "A")
        #expect(try store.pinned().map(\.content) == ["c", "b", "a"])
    }

    @Test func setPinOrderAndUnpin() throws {
        let store = try ClipStore(path: nil)
        let now = Date()
        for (i, text) in ["a", "b", "c"].enumerated() {
            try store.save(make(text, at: now.addingTimeInterval(Double(i))))
            try store.setPinned(try id(store, text), true)
        }
        try store.setPinOrder([try id(store, "a"), try id(store, "c")])
        #expect(try store.pinned().map(\.content) == ["a", "c", "b"])

        // 外してからもう一度ピン留めすると先頭に戻る
        try store.setPinned(try id(store, "b"), false)
        #expect(try store.pinned().map(\.content) == ["a", "c"])
        try store.setPinned(try id(store, "b"), true)
        #expect(try store.pinned().map(\.content) == ["b", "a", "c"])
        // 検索しても並び順のまま
        try store.setTitle(try id(store, "c"), "メモ c")
        try store.setTitle(try id(store, "a"), "メモ a")
        #expect(try store.pinned(query: "メモ").map(\.content) == ["a", "c"])
    }

    @Test func moveWithinAFilteredList() {
        let all = ["a", "x", "b", "y", "c"]
        let folder = ["a", "b", "c"]
        // c を先頭へ。フォルダの外の x・y の並びは変えない
        #expect(PinFolders.move(["c"], in: all, visible: folder, before: "a") == ["c", "a", "x", "b", "y"])
        // a を末尾へ（見えている最後の c の後ろ）
        #expect(PinFolders.move(["a"], in: all, visible: folder, before: nil) == ["x", "b", "y", "c", "a"])
        // まとめて動かすと、動かすものどうしの順は保つ
        #expect(PinFolders.move(["c", "a"], in: all, visible: folder, before: "b") == ["x", "a", "c", "b", "y"])
        // 動かすものの前へは動かさない。一覧に無いものも動かさない
        #expect(PinFolders.move(["a", "b"], in: all, visible: folder, before: "b") == all)
        #expect(PinFolders.move(["z"], in: all, visible: folder, before: "a") == all)
        // 見えているのが動かすものだけなら、末尾へは動かさない
        #expect(PinFolders.move(["x"], in: all, visible: ["x"], before: nil) == all)
    }

    @Test func foldersFollowTheUserOrder() {
        #expect(PinFolders.ordered(["仕事", "メール", "個人"], by: ["個人", "なくなった", "仕事"]) == ["個人", "仕事", "メール"])
        #expect(PinFolders.renamed(["a", "b"], from: "a", to: "c") == ["c", "b"])
        // 名前を変えて 1 つにまとめたら、元の位置は外す
        #expect(PinFolders.renamed(["a", "b"], from: "a", to: "b") == ["b"])

        func item(_ folder: String?) -> ClipItem {
            ClipItem(createdAt: Date(), content: folder ?? "-", contentHash: folder ?? "-", contentType: .text,
                     source: .unknown, sensitivity: .normal, retention: .pinned, externalAllowed: true,
                     expiresAt: nil, reasons: [], folder: folder)
        }
        let groups = PinFolders.group([item("b"), item(nil), item("a")], folderOrder: ["b"])
        #expect(groups.map(\.folder) == ["b", "a", nil])
    }

    @Test func migratesOldDatabasesRecentFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClingCling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clingcling.sqlite")

        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let created = sqlite3_exec(db, """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY, created_at REAL NOT NULL, last_copied_at REAL NOT NULL, content TEXT NOT NULL,
                content_hash TEXT NOT NULL UNIQUE, content_type TEXT NOT NULL, source_bundle_id TEXT, source_name TEXT,
                sensitivity TEXT NOT NULL, retention TEXT NOT NULL, copy_count INTEGER NOT NULL DEFAULT 1,
                external_allowed INTEGER NOT NULL, reasons TEXT NOT NULL DEFAULT '', image_file TEXT,
                image_width INTEGER, image_height INTEGER, image_text TEXT, title TEXT, folder TEXT
            );
            INSERT INTO clips (id, created_at, last_copied_at, content, content_hash, content_type, sensitivity,
                retention, external_allowed)
            VALUES ('\(UUID().uuidString)', 0, 10, 'older', 'h-older', 'text', 'normal', 'pinned', 1),
                   ('\(UUID().uuidString)', 0, 20, 'newer', 'h-newer', 'text', 'normal', 'pinned', 1),
                   ('\(UUID().uuidString)', 0, 30, 'history', 'h-history', 'text', 'normal', 'normal', 1);
            """, nil, nil, nil)
        sqlite3_close(db)
        try #require(created == SQLITE_OK)

        let store = try ClipStore(path: url)
        #expect(try store.pinned().map(\.content) == ["newer", "older"])
        // 移行の後にピン留めしたものは先頭に来る
        try store.setPinned(try id(store, "history"), true)
        #expect(try store.pinned().map(\.content) == ["history", "newer", "older"])
    }
}
