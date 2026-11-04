import Foundation

/// ピン留めの別名とフォルダ。
///
/// - 別名やフォルダを付けた Item はピン留めになる（期間・件数の上限で消えないように）
/// - フォルダは 1 階層で、名前だけで表す。入っている Item がなくなればフォルダも消える
/// - ピン留めを外すとフォルダからも出る（別名は残す）
public enum PinFolders {
    /// 別名の最大の長さ
    public static let maxTitleLength = 100
    /// フォルダ名の最大の長さ
    public static let maxFolderLength = 40

    /// 入力された別名を保存する形にする。空なら nil（別名を外す）。
    public static func normalizedTitle(_ raw: String) -> String? {
        normalized(raw, limit: maxTitleLength)
    }

    /// 入力されたフォルダ名を保存する形にする。空なら nil（フォルダから出す）。
    public static func normalizedFolder(_ raw: String) -> String? {
        normalized(raw, limit: maxFolderLength)
    }

    /// 改行やタブを空白にまとめ、前後の空白を除いて長さを切る
    private static func normalized(_ raw: String, limit: Int) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let text = String(words.joined(separator: " ").prefix(limit)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// フォルダの並び順（Finder と同じく、数字を数として比べる）
    public static func sorted(_ folders: some Sequence<String>) -> [String] {
        Set(folders).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// フォルダを、ユーザーが決めた順（`order`）に並べる。`order` に無いフォルダは後ろに名前順で続ける。
    public static func ordered(_ folders: some Sequence<String>, by order: [String]) -> [String] {
        let names = sorted(folders)
        let known = order.filter { names.contains($0) }
        return known + names.filter { !known.contains($0) }
    }

    /// ピン留めの Item をフォルダごとに分ける。Finder と同じくフォルダが先（`order` の順、`ordered(_:by:)`）、
    /// 続いてフォルダに入っていないもの。各グループの中は渡された順のまま。
    public static func group(_ items: [ClipItem], folderOrder order: [String] = []) -> [(folder: String?, items: [ClipItem])] {
        var groups: [(folder: String?, items: [ClipItem])] = ordered(items.compactMap(\.folder), by: order).map { folder in
            (folder, items.filter { $0.folder == folder })
        }
        let loose = items.filter { $0.folder == nil }
        if !loose.isEmpty { groups.append((nil, loose)) }
        return groups
    }

    /// 並べ替え。`all` の中の `moving` を、`target` の前（nil なら見えている一覧 `visible` の最後の後ろ）へまとめて動かす。
    /// `visible` は `all` の一部を同じ順で並べたもの（フォルダの中など）。動かすものどうしの順は保つ。
    /// フォルダの中で動かしても、ほかのフォルダの並びは変えない。
    public static func move<ID: Equatable>(_ moving: [ID], in all: [ID], visible: [ID], before target: ID?) -> [ID] {
        let moving = all.filter { moving.contains($0) }
        guard !moving.isEmpty else { return all }
        if let target, moving.contains(target) { return all }
        var result = all.filter { !moving.contains($0) }
        let position: Int
        if let target {
            guard let index = result.firstIndex(of: target) else { return all }
            position = index
        } else if let last = visible.last(where: { !moving.contains($0) }), let index = result.firstIndex(of: last) {
            position = index + 1
        } else {
            return all
        }
        result.insert(contentsOf: moving, at: position)
        return result
    }

    /// 並び順のフォルダ名を変える。変えた先の名前が既に並んでいれば（1 つにまとめたとき）、元の位置を外す。
    public static func renamed(_ order: [String], from old: String, to new: String) -> [String] {
        guard order.contains(old) else { return order }
        if order.contains(new) { return order.filter { $0 != old } }
        return order.map { $0 == old ? new : $0 }
    }

    /// `query` に一致するフォルダ（`SearchQuery` と同じく、大文字小文字・全角半角・かなの違いを無視）
    public static func filter(_ folders: [String], query: String) -> [String] {
        let search = SearchQuery(query)
        guard !search.isEmpty else { return folders }
        return folders.filter { folder in
            let name = SearchQuery.normalize(folder)
            return search.terms.allSatisfy { name.contains($0) }
        }
    }

    /// `name` と同じフォルダ（違いを無視して同じ名前）があればその名前。新しく作るときに重ねないため。
    public static func existing(_ name: String, in folders: [String]) -> String? {
        let key = SearchQuery.normalize(name)
        return folders.first { SearchQuery.normalize($0) == key }
    }
}

extension ClipItem {
    /// 本文を書き換えられるか。テキストの Item だけ（画像・ファイルは中身を書き換えられない）。
    /// 伏せて表示する Item（Secret・ランダムな文字列を含むもの）は、編集欄で本文が読めてしまうので書き換えさせない。
    public var isContentEditable: Bool {
        !isTemporary && !isImage && !isFile && sensitivity < .suspicious
    }
}
