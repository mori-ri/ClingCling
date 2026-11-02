import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): "SQLite: \(m)" }
    }
}

/// Clipboard 履歴のローカル保存。
///
/// - `temporary` の Item（Secret / OTP）はディスクに書かず、メモリ上でのみ保持する。
/// - 同じ内容の再コピーは `content_hash` で重複排除し、`copy_count` / `last_copied_at` を更新する。
/// - 画像本体は DB の隣の `images/` に PNG で保存する（0600）。行が消えたらファイルも消す。
/// - メインスレッドからのみ使う前提。
public final class ClipStore: ActionStatsProvider {
    private var db: OpaquePointer?
    private var ephemeral: [ClipItem] = []
    /// 画像本体の保存先
    public let imagesDirectory: URL

    /// `path == nil` ならインメモリ DB（テスト用。画像は一時ディレクトリに置く）
    public init(path: URL?) throws {
        let location = path?.path ?? ":memory:"
        let fm = FileManager.default
        if let dir = path?.deletingLastPathComponent() {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            imagesDirectory = dir.appendingPathComponent("images", isDirectory: true)
            Self.excludeFromBackup(dir)
        } else {
            imagesDirectory = fm.temporaryDirectory.appendingPathComponent("ClingCling-\(UUID().uuidString)/images", isDirectory: true)
        }
        try fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(location, &db) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        if let path {
            // 履歴ファイルは本人のみ読み書き可能にする
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    /// 履歴を Time Machine に残さない。残すと、消した履歴がバックアップから読めてしまう。
    /// 失敗しても履歴の保存はできるので、起動は止めない。
    private static func excludeFromBackup(_ directory: URL) {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClingCling", isDirectory: true).appendingPathComponent("clingcling.sqlite")
    }

    private func migrate() throws {
        try exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            last_copied_at REAL NOT NULL,
            content TEXT NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            content_type TEXT NOT NULL,
            source_bundle_id TEXT,
            source_name TEXT,
            sensitivity TEXT NOT NULL,
            retention TEXT NOT NULL,
            copy_count INTEGER NOT NULL DEFAULT 1,
            external_allowed INTEGER NOT NULL,
            reasons TEXT NOT NULL DEFAULT '',
            image_file TEXT,
            image_width INTEGER,
            image_height INTEGER
        );
        CREATE INDEX IF NOT EXISTS clips_last_copied ON clips(last_copied_at DESC);
        CREATE TABLE IF NOT EXISTS action_stats (
            content_type TEXT NOT NULL,
            source_app TEXT NOT NULL,
            action TEXT NOT NULL,
            action_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (content_type, source_app, action)
        );
        CREATE TABLE IF NOT EXISTS action_events (
            at REAL NOT NULL,
            content_type TEXT NOT NULL,
            source_app TEXT NOT NULL,
            action TEXT NOT NULL,
            position INTEGER NOT NULL
        );
        """)
    }

    // MARK: - Clips

    /// 保存して、重複排除後の Item を返す。画像 Item は `imageData`（PNG）も渡す。
    @discardableResult
    public func save(_ item: ClipItem, imageData: Data? = nil) throws -> ClipItem {
        if let image = item.image {
            guard let imageData else { throw StoreError.sqlite("image data missing") }
            try writeImage(imageData, named: image.fileName)
        }
        if item.isTemporary {
            if let i = ephemeral.firstIndex(where: { $0.contentHash == item.contentHash }) {
                ephemeral[i].lastCopiedAt = item.createdAt
                ephemeral[i].expiresAt = item.expiresAt
                ephemeral[i].copyCount += 1
                return ephemeral[i]
            }
            ephemeral.append(item)
            return item
        }

        if var existing = try fetch(where: "content_hash = ?", [item.contentHash]).first {
            existing.lastCopiedAt = item.createdAt
            existing.copyCount += 1
            existing.source = item.source
            // 判定ロジックが更新されている可能性があるので、最新の判定で上書きする（Pin は維持）
            existing.contentType = item.contentType
            existing.sensitivity = item.sensitivity
            existing.externalAllowed = item.externalAllowed
            existing.reasons = item.reasons
            try run("""
                UPDATE clips SET last_copied_at = ?, copy_count = ?, source_bundle_id = ?, source_name = ?,
                content_type = ?, sensitivity = ?, external_allowed = ?, reasons = ? WHERE id = ?
                """, [existing.lastCopiedAt.timeIntervalSince1970, existing.copyCount, existing.source.bundleID,
                      existing.source.name, existing.contentType.rawValue, existing.sensitivity.rawValue,
                      existing.externalAllowed ? 1 : 0, existing.reasons.joined(separator: "\n"),
                      existing.id.uuidString])
            return existing
        }

        try run("""
            INSERT INTO clips (id, created_at, last_copied_at, content, content_hash, content_type, source_bundle_id,
            source_name, sensitivity, retention, copy_count, external_allowed, reasons, image_file, image_width, image_height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [item.id.uuidString, item.createdAt.timeIntervalSince1970, item.lastCopiedAt.timeIntervalSince1970,
                  item.content, item.contentHash, item.contentType.rawValue, item.source.bundleID, item.source.name,
                  item.sensitivity.rawValue, item.retention.rawValue, item.copyCount, item.externalAllowed ? 1 : 0,
                  item.reasons.joined(separator: "\n"), item.image?.fileName, item.image?.width, item.image?.height])
        return item
    }

    /// 新しい順。`query` は本文・アプリ名の部分一致（`SearchQuery`: 大文字小文字・全角半角・かなの違いを無視）。
    public func recent(limit: Int = 200, query: String = "", pinnedOnly: Bool = false, now: Date = Date()) throws -> [ClipItem] {
        let search = SearchQuery(query)
        let whereSQL = pinnedOnly ? "retention = 'pinned'" : "1"
        var items: [ClipItem]
        if search.isEmpty {
            items = try fetch(where: whereSQL + " ORDER BY last_copied_at DESC LIMIT \(limit)", [])
        } else {
            // SQLite の LIKE は ASCII 以外の大文字小文字や かな・全角半角を区別してしまうので、Swift 側で絞り込む。
            // 履歴は件数上限（既定 500 件）があるので全件を見ても軽い。
            items = try fetch(where: whereSQL + " ORDER BY last_copied_at DESC", [])
                .filter { matches(search, $0) }
            items = Array(items.prefix(limit))
        }

        if !pinnedOnly {
            let live = ephemeral.filter { ($0.expiresAt ?? .distantFuture) > now }
                .filter { search.isEmpty || matches(search, $0) }
            items = (items + live).sorted { $0.lastCopiedAt > $1.lastCopiedAt }
            items = Array(items.prefix(limit))
        }
        return items
    }

    /// 正規化済みの検索対象（本文 + アプリ名）。打鍵ごとに作り直さないよう内容のハッシュで覚えておく。
    /// 一時 Item（Secret / OTP）は期限後にメモリへ残らないようキャッシュしない。
    private var searchTextCache: [String: String] = [:]

    private func matches(_ search: SearchQuery, _ item: ClipItem) -> Bool {
        let key = item.contentHash + "\u{1F}" + (item.source.name ?? "")
        let text: String
        if let cached = searchTextCache[key] {
            text = cached
        } else {
            text = SearchQuery.normalize(item.content + "\n" + (item.source.name ?? ""))
            if !item.isTemporary {
                if searchTextCache.count > 4_000 { searchTextCache.removeAll() }
                searchTextCache[key] = text
            }
        }
        return search.matches(searchText: text, contentType: item.contentType)
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) throws {
        // 一時 Item は Pin できない（Secret を永続化させないため）
        try run("UPDATE clips SET retention = ? WHERE id = ?",
                [pinned ? Retention.pinned.rawValue : Retention.normal.rawValue, id.uuidString])
    }

    /// 再利用した Item を先頭に移動する
    public func touch(_ id: UUID, at date: Date = Date()) throws {
        if let i = ephemeral.firstIndex(where: { $0.id == id }) {
            ephemeral[i].lastCopiedAt = date
            return
        }
        try run("UPDATE clips SET last_copied_at = ? WHERE id = ?", [date.timeIntervalSince1970, id.uuidString])
    }

    public func delete(_ id: UUID) throws {
        ephemeral.removeAll { $0.id == id }
        searchTextCache.removeAll()
        try run("DELETE FROM clips WHERE id = ?", [id.uuidString])
        removeOrphanImages()
    }

    public func clear(keepPinned: Bool = true) throws {
        ephemeral.removeAll()
        searchTextCache.removeAll()
        try run(keepPinned ? "DELETE FROM clips WHERE retention != 'pinned'" : "DELETE FROM clips", [])
        try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        removeOrphanImages()
    }

    /// 期限切れの一時 Item、保存期間・件数を超えた Item を削除する（Pin は対象外）
    public func prune(now: Date = Date(), retentionDays: Int, historyLimit: Int) throws {
        ephemeral.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
            try run("DELETE FROM clips WHERE retention != 'pinned' AND last_copied_at < ?", [cutoff])
        }
        if historyLimit > 0 {
            try run("""
                DELETE FROM clips WHERE retention != 'pinned' AND id NOT IN (
                    SELECT id FROM clips WHERE retention != 'pinned' ORDER BY last_copied_at DESC LIMIT ?)
                """, [historyLimit])
        }
        removeOrphanImages()
    }

    // MARK: - Images

    public func imageURL(for item: ClipItem) -> URL? {
        item.image.map { imagesDirectory.appendingPathComponent($0.fileName) }
    }

    public func imageData(for item: ClipItem) -> Data? {
        imageURL(for: item).flatMap { try? Data(contentsOf: $0) }
    }

    private func writeImage(_ data: Data, named name: String) throws {
        let url = imagesDirectory.appendingPathComponent(name)
        // 同じ内容は同じファイル名（ハッシュ）なので、既にあれば書かない
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.sqlite("could not write image")
        }
    }

    /// どの行からも参照されていない画像ファイルを消す
    private func removeOrphanImages() {
        var referenced: Set<String> = []
        try? query("SELECT image_file FROM clips WHERE image_file IS NOT NULL", []) { stmt in
            if let name = Self.text(stmt, 0) { referenced.insert(name) }
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: imagesDirectory.path)) ?? [] where !referenced.contains(name) {
            try? fm.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Action statistics

    /// Action 選択を記録する。`position` は表示位置（0 = 左端の推奨 Action）。
    public func recordAction(_ action: SmartAction, for item: ClipItem, position: Int, at date: Date = Date()) throws {
        try run("""
            INSERT INTO action_stats (content_type, source_app, action, action_count) VALUES (?, ?, ?, 1)
            ON CONFLICT(content_type, source_app, action) DO UPDATE SET action_count = action_count + 1
            """, [item.contentType.rawValue, item.source.statsKey, action.rawValue])
        try run("INSERT INTO action_events (at, content_type, source_app, action, position) VALUES (?, ?, ?, ?, ?)",
                [date.timeIntervalSince1970, item.contentType.rawValue, item.source.statsKey, action.rawValue, position])
    }

    public func actionCounts(contentType: ContentType, sourceKey: String?) -> [SmartAction: Int] {
        var sql = "SELECT action, SUM(action_count) FROM action_stats WHERE content_type = ?"
        var params: [Any?] = [contentType.rawValue]
        if let sourceKey {
            sql += " AND source_app = ?"
            params.append(sourceKey)
        }
        sql += " GROUP BY action"
        var result: [SmartAction: Int] = [:]
        try? query(sql, params) { stmt in
            if let action = SmartAction(rawValue: Self.text(stmt, 0) ?? "") {
                result[action] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return result
    }

    /// 最重要 KPI: First Action Selection Rate
    public func firstActionSelectionRate() -> (rate: Double, total: Int) {
        var total = 0, first = 0
        try? query("SELECT COUNT(*), SUM(CASE WHEN position = 0 THEN 1 ELSE 0 END) FROM action_events", []) { stmt in
            total = Int(sqlite3_column_int64(stmt, 0))
            first = Int(sqlite3_column_int64(stmt, 1))
        }
        return (total == 0 ? 0 : Double(first) / Double(total), total)
    }

    public func resetLearning() throws {
        try exec("DELETE FROM action_stats; DELETE FROM action_events;")
    }

    // MARK: - SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Any?]) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ params: [Any?], row: (OpaquePointer?) -> Void) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }

    private func fetch(where clause: String, _ params: [Any?]) throws -> [ClipItem] {
        var items: [ClipItem] = []
        try query("""
            SELECT id, created_at, last_copied_at, content, content_hash, content_type, source_bundle_id, source_name,
            sensitivity, retention, copy_count, external_allowed, reasons, image_file, image_width, image_height
            FROM clips WHERE \(clause)
            """, params) { s in
            let reasons = Self.text(s, 12) ?? ""
            let image = Self.text(s, 13).map {
                ClipImage(fileName: $0, width: Int(sqlite3_column_int64(s, 14)), height: Int(sqlite3_column_int64(s, 15)))
            }
            items.append(ClipItem(
                id: UUID(uuidString: Self.text(s, 0) ?? "") ?? UUID(),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                content: Self.text(s, 3) ?? "",
                contentHash: Self.text(s, 4) ?? "",
                contentType: ContentType(rawValue: Self.text(s, 5) ?? "") ?? .other,
                source: SourceApp(bundleID: Self.text(s, 6), name: Self.text(s, 7)),
                // 不明な値は最も厳しい側に倒す
                sensitivity: Sensitivity(rawValue: Self.text(s, 8) ?? "") ?? .secret,
                retention: Retention(rawValue: Self.text(s, 9) ?? "") ?? .normal,
                copyCount: Int(sqlite3_column_int64(s, 10)),
                externalAllowed: sqlite3_column_int(s, 11) == 1,
                expiresAt: nil,
                reasons: reasons.isEmpty ? [] : reasons.components(separatedBy: "\n"),
                image: image
            ))
        }
        return items
    }
}
