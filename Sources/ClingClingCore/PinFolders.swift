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

    /// ピン留めの Item をフォルダごとに分ける。フォルダに入っていないものが先、続いてフォルダの名前順。
    /// 各グループの中は渡された順のまま。
    public static func group(_ items: [ClipItem]) -> [(folder: String?, items: [ClipItem])] {
        let loose = items.filter { $0.folder == nil }
        var groups: [(folder: String?, items: [ClipItem])] = loose.isEmpty ? [] : [(nil, loose)]
        for folder in sorted(items.compactMap(\.folder)) {
            groups.append((folder, items.filter { $0.folder == folder }))
        }
        return groups
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
