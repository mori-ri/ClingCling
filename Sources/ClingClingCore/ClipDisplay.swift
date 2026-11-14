import Foundation

/// 画面に出す本文。Secret / 未知の Token は肩越しに見られないようマスクする。
/// - 既知の Secret を含む・本文のほとんどが Token → 全体を伏せる
/// - ランダムに見える文字列（ID など）を含むだけ → その部分だけを伏せる
///   （URL や Markdown の中にランダムな ID が 1 つあるだけで全体が読めなくならないように）
///
/// 文字を読み取った画像は、ラベル（「画像 1280×720」）の代わりに読み取った文字を本文として扱う。
extension ClipItem {
    /// 1 行目から最大 3 行・この文字数までを検査して一覧に出す
    private static let rowScanLimit = 2_000
    private static let rowDisplayLimit = 300

    /// 本文全体を伏せる Item。一致箇所のハイライトもしない。
    /// 既知の Secret は規則に一致した部分の外（秘密鍵の本体など）にも秘密が続くことがあるので、部分マスクにしない。
    /// ただし URL の Item で、秘密が URL のパラメータやパスワードの値だけのときは、その値だけを伏せる。
    public var isFullyMasked: Bool {
        guard contentType != .verificationCode else { return false }
        if contentType == .url, sensitivity == .secret {
            return reasons.contains(where: SecretDetector.fullMaskRules.contains)
        }
        return sensitivity == .secret || (sensitivity >= .suspicious && contentType == .credential)
    }

    private var needsRedaction: Bool {
        sensitivity >= .suspicious && contentType != .verificationCode
    }

    /// 一覧の行に出す本文。ファイルは名前（複数なら「a.pdf ほか 2 件」）。
    public func rowText(detector: SecretDetector) -> String {
        if isFile { return fileSummary }
        let collapsed = displayContent
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ⏎ ")
        guard needsRedaction else { return String(collapsed.prefix(Self.rowDisplayLimit)) }
        if isFullyMasked { return SecretDetector.mask(collapsed) }
        return String(detector.redact(Self.cut(collapsed, at: Self.rowScanLimit)).prefix(Self.rowDisplayLimit))
    }

    /// プレビューに出す本文。改行を保ち、先頭の `limit` 文字までを出す。
    /// 全体を伏せる Item は、ここで本文が読めてしまわないよう一覧と同じ表示にする。
    public func fullText(limit: Int, detector: SecretDetector) -> String {
        if isFullyMasked { return rowText(detector: detector) }
        let text = displayContent
        guard needsRedaction else { return String(text.prefix(limit)) }
        return detector.redact(Self.cut(text, at: limit))
    }

    /// ファイル Item の名前。複数なら先頭の名前と残りの件数。
    public var fileSummary: String {
        let paths = filePaths
        guard let first = paths.first else { return content }
        let name = CopiedFiles.displayName(of: first)
        return paths.count == 1 ? name : String(localized: "\(name) ほか \(paths.count - 1) 件")
    }

    /// `fullText(limit:)` が本文を途中で切るか。全体を伏せる Item は切らずに伏せるので false。
    public func isFullTextCut(limit: Int) -> Bool {
        !isFullyMasked && Self.isLonger(displayContent, than: limit)
    }

    /// `count` は全体を数えるので、長い本文でも先頭だけを見る
    private static func isLonger(_ text: String, than limit: Int) -> Bool {
        !text.dropFirst(limit).isEmpty
    }

    /// 切った位置で Token が途中までしか残らないと検出から漏れるので、末尾の書きかけの Token ごと落とす
    private static func cut(_ text: String, at limit: Int) -> String {
        guard isLonger(text, than: limit) else { return text }
        var cut = String(text.prefix(limit))
        while let last = cut.last, last.isLetter || last.isNumber || "+/=_-.~".contains(last) {
            cut.removeLast()
        }
        return cut
    }
}
