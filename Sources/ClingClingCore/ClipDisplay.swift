import Foundation

/// 画面に出す本文。Secret / 未知の Token は肩越しに見られないようマスクする。
/// - 既知の Secret を含む・本文のほとんどが Token → 全体を伏せる
/// - ランダムに見える文字列（ID など）を含むだけ → その部分だけを伏せる
///   （URL や Markdown の中にランダムな ID が 1 つあるだけで全体が読めなくならないように）
extension ClipItem {
    /// 1 行目から最大 3 行・この文字数までを検査して一覧に出す
    private static let rowScanLimit = 2_000
    private static let rowDisplayLimit = 300

    /// 本文全体を伏せる Item。一致箇所のハイライトもしない。
    /// 既知の Secret は規則に一致した部分の外（秘密鍵の本体など）にも秘密が続くことがあるので、部分マスクにしない。
    public var isFullyMasked: Bool {
        guard contentType != .verificationCode else { return false }
        return sensitivity == .secret || (sensitivity >= .suspicious && contentType == .credential)
    }

    private var needsRedaction: Bool {
        sensitivity >= .suspicious && contentType != .verificationCode
    }

    /// 一覧の行に出す本文
    public func rowText(detector: SecretDetector) -> String {
        let collapsed = content
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
        guard needsRedaction else { return String(content.prefix(limit)) }
        return detector.redact(Self.cut(content, at: limit))
    }

    /// 切った位置で Token が途中までしか残らないと検出から漏れるので、末尾の書きかけの Token ごと落とす
    private static func cut(_ text: String, at limit: Int) -> String {
        guard !text.dropFirst(limit).isEmpty else { return text }
        var cut = String(text.prefix(limit))
        while let last = cut.last, last.isLetter || last.isNumber || "+/=_-.~".contains(last) {
            cut.removeLast()
        }
        return cut
    }
}
