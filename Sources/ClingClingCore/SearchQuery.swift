import Foundation

/// 履歴検索の一致判定。
///
/// - 大文字小文字・全角半角・ひらがなとカタカナの違いを無視する（「くりっぷ」で「クリップ」「ｸﾘｯﾌﾟ」が見つかる）
/// - 空白（全角スペースを含む）で区切った語はすべて含むものに絞る（AND）
/// - 語が分類名（`url` / `code` など）と一致すれば、その種類の Item にも一致する
public struct SearchQuery: Sendable, Equatable {
    /// 正規化済みの検索語
    public let terms: [String]

    public init(_ raw: String) {
        terms = raw.split(whereSeparator: \.isWhitespace).map { Self.normalize(String($0)) }.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// 比較用に正規化する。ひらがな → カタカナ → 半角、最後に小文字化。
    public static func normalize(_ text: String) -> String {
        var s = text.applyingTransform(.hiraganaToKatakana, reverse: false) ?? text
        s = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        return s.lowercased()
    }

    /// `searchText` は `normalize` 済みの本文（＋アプリ名）
    public func matches(searchText: String, contentType: ContentType) -> Bool {
        terms.allSatisfy { $0 == contentType.rawValue || searchText.contains($0) }
    }

    /// `text` の中で検索語に一致する範囲（ハイライト用）。正規化で文字数が変わっても元の位置を返す。
    public func ranges(in text: String) -> [Range<String.Index>] {
        guard !isEmpty, !text.isEmpty else { return [] }
        // 1 文字ずつ正規化し、正規化後の各文字がどの元の文字から来たかを覚えておく
        var normalized: [Character] = []
        var owners: [String.Index] = []
        for index in text.indices {
            for c in Self.normalize(String(text[index])) {
                normalized.append(c)
                owners.append(index)
            }
        }

        var found: [Range<String.Index>] = []
        for term in terms {
            let needle = Array(term)
            guard !needle.isEmpty, needle.count <= normalized.count else { continue }
            var i = 0
            while i <= normalized.count - needle.count {
                if normalized[i..<(i + needle.count)].elementsEqual(needle) {
                    let lower = owners[i]
                    let upper = text.index(after: owners[i + needle.count - 1])
                    found.append(lower..<upper)
                    i += needle.count
                } else {
                    i += 1
                }
            }
        }
        return Self.merged(found)
    }

    /// 重なる・隣り合う範囲をまとめる
    static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
