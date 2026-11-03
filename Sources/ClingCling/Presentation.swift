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

    /// 一覧に出す本文。マスクの規則は `ClipItem.rowText` を参照。
    static func preview(_ item: ClipItem) -> String {
        // 文字を読み取る前に保存した画像は、コピーし直すと同じハッシュのまま読み取った文字が付く
        let key = item.contentHash + (item.recognizedText == nil ? "" : "+text")
        if let cached = previewCache[item.id], cached.key == key { return cached.text }
        let text = item.rowText(detector: detector)
        // 一時 Item（OTP など）は期限後にメモリへ残らないようキャッシュしない
        guard !item.isTemporary else { return text }
        if previewCache.count > 2_000 { previewCache.removeAll() }
        previewCache[item.id] = (key, text)
        return text
    }

    /// プレビューのカードに出す本文の上限。これを超える長さは SwiftUI の `Text` の組版が重い。
    static let fullTextLimit = 20_000

    /// プレビューのカードに出す本文
    static func fullText(_ item: ClipItem) -> String {
        item.fullText(limit: fullTextLimit, detector: detector)
    }

    /// `preview` の結果（再描画のたびに Secret 検出をやり直さないため）
    private static var previewCache: [UUID: (key: String, text: String)] = [:]
    private static let detector = SecretDetector()

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

    /// 確認画面に出す Action 名。確認が出る URL はブラウザで開くとは限らない。
    static func confirmationTitle(for action: SmartAction) -> String {
        action == .open ? String(localized: "リンクを開く") : title(for: action)
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
        case .pasteText: String(localized: "テキストで貼り付け")
        }
    }
}
