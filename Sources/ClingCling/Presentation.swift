import ClingClingCore
import SwiftUI

/// 一覧表示用の文字列整形
enum Presentation {
    static func icon(for type: ContentType) -> String {
        switch type {
        case .text: "text.alignleft"
        case .url: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .command: "terminal"
        case .error: "exclamationmark.triangle"
        case .email: "envelope"
        case .address: "mappin.and.ellipse"
        case .json: "curlybraces"
        case .credential: "key"
        case .verificationCode: "number"
        case .image: "photo"
        case .other: "doc"
        }
    }

    static func isMonospaced(_ type: ContentType) -> Bool {
        [.code, .command, .json, .error, .credential].contains(type)
    }

    /// 一覧に出す本文。Secret / 未知の Token は肩越しに見られないようマスクする。
    /// - 既知の Secret を含む・本文のほとんどが Token → 全体を伏せる
    /// - ランダムに見える文字列（ID など）を含むだけ → その部分だけを伏せる
    ///   （URL や Markdown の中にランダムな ID が 1 つあるだけで全体が読めなくならないように）
    static func preview(_ item: ClipItem) -> String {
        if let cached = previewCache[item.id], cached.hash == item.contentHash { return cached.text }
        let text = makePreview(item)
        // 一時 Item（OTP など）は期限後にメモリへ残らないようキャッシュしない
        guard !item.isTemporary else { return text }
        if previewCache.count > 2_000 { previewCache.removeAll() }
        previewCache[item.id] = (item.contentHash, text)
        return text
    }

    /// `preview` の結果（再描画のたびに Secret 検出をやり直さないため）
    private static var previewCache: [UUID: (hash: String, text: String)] = [:]
    private static let detector = SecretDetector()
    /// 1 行目から最大 3 行・この文字数までを検査して表示する
    private static let scanLimit = 2_000
    private static let displayLimit = 300

    private static func makePreview(_ item: ClipItem) -> String {
        var collapsed = item.content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ⏎ ")
        guard item.sensitivity >= .suspicious, item.contentType != .verificationCode else {
            return String(collapsed.prefix(displayLimit))
        }
        if isFullyMasked(item) { return mask(collapsed) }
        if collapsed.count > scanLimit {
            // 切った位置で Token が途中までしか残らないと検出から漏れるので、末尾の書きかけの Token ごと落とす
            collapsed = String(collapsed.prefix(scanLimit))
            while let last = collapsed.last, last.isLetter || last.isNumber || "+/=_-.~".contains(last) {
                collapsed.removeLast()
            }
        }
        return String(detector.redact(collapsed).prefix(displayLimit))
    }

    /// 本文全体を伏せる Item。一致箇所のハイライトもしない。
    /// 既知の Secret は規則に一致した部分の外（秘密鍵の本体など）にも秘密が続くことがあるので、部分マスクにしない。
    static func isFullyMasked(_ item: ClipItem) -> Bool {
        guard item.contentType != .verificationCode else { return false }
        return item.sensitivity == .secret || (item.sensitivity >= .suspicious && item.contentType == .credential)
    }

    static func mask(_ text: String) -> String {
        SecretDetector.mask(text)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()

    static func meta(_ item: ClipItem, now: Date = Date()) -> String {
        // 数秒単位で表示が揺れないよう、1 分未満は「今」にまとめる
        let date = now.timeIntervalSince(item.lastCopiedAt) < 60 ? now : item.lastCopiedAt
        var parts = [relative.localizedString(for: date, relativeTo: now)]
        if let name = item.source.name { parts.append(name) }
        if item.copyCount > 1 { parts.append("×\(item.copyCount)") }
        return parts.joined(separator: " · ")
    }

    /// 行の右端に出す短いタグ。消去待ちの Sensitive Item だけに付ける。
    static func tag(_ item: ClipItem, now: Date = Date()) -> String? {
        guard item.isTemporary, let expires = item.expiresAt else { return nil }
        let minutes = max(1, Int(ceil(expires.timeIntervalSince(now) / 60)))
        return String(localized: "\(minutes)分で消去")
    }

    /// 行のアイコン。Sensitive な Item は種類より「鍵」を優先する。
    static func rowIcon(for item: ClipItem) -> String {
        item.sensitivity >= .suspicious ? "lock" : icon(for: item.contentType)
    }

    /// 一致箇所をハイライトした本文。全体をマスクした本文は一致位置が無意味なので強調しない。
    /// 検索と同じく、大文字小文字・全角半角・ひらがなとカタカナの違いを無視して探す。
    static func highlighted(_ text: String, query: String, masked: Bool, selected: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        guard !masked else { return attributed }
        for range in SearchQuery(query).ranges(in: text) {
            guard let target = Range(range, in: attributed) else { continue }
            attributed[target].backgroundColor = selected ? Color.white.opacity(0.28) : Theme.brandSpark.opacity(0.35)
        }
        return attributed
    }

    /// ポップアップに出す Action 名
    static func title(for action: SmartAction) -> String {
        switch action {
        case .copy: String(localized: "コピー")
        case .open: String(localized: "ブラウザで開く")
        case .markdown: String(localized: "Markdown リンクをコピー")
        case .explain: String(localized: "説明する")
        case .search: String(localized: "Web で検索")
        case .run: String(localized: "Terminal で実行")
        case .polish: String(localized: "文章を整える")
        case .shorten: String(localized: "短くする")
        case .translate: String(localized: "翻訳する")
        case .newMail: String(localized: "メールを作成")
        case .openMaps: String(localized: "マップで開く")
        case .format: String(localized: "JSON を整形")
        case .inspect: String(localized: "JSON の構造を見る")
        case .saveImage: String(localized: "ダウンロードに保存")
        }
    }
}
