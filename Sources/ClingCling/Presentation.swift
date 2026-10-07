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
    static func preview(_ item: ClipItem) -> String {
        let collapsed = item.content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ⏎ ")
        guard item.sensitivity >= .suspicious, item.contentType != .verificationCode else {
            return String(collapsed.prefix(300))
        }
        return mask(collapsed)
    }

    static func mask(_ text: String) -> String {
        let compact = text.trimmingCharacters(in: .whitespaces)
        guard compact.count > 12 else { return String(repeating: "•", count: 8) }
        return "\(compact.prefix(4))••••••••\(compact.suffix(4))"
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
        return "\(minutes)分で消去"
    }

    /// 行のアイコン。Sensitive な Item は種類より「鍵」を優先する。
    static func rowIcon(for item: ClipItem) -> String {
        item.sensitivity >= .suspicious ? "lock" : icon(for: item.contentType)
    }

    /// 一致箇所をハイライトした本文。マスク済みの本文は一致位置が無意味なので強調しない。
    static func highlighted(_ text: String, query: String, masked: Bool, selected: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !masked, !q.isEmpty, let range = attributed.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return attributed
        }
        attributed[range].backgroundColor = selected ? Color.white.opacity(0.28) : Color.yellow.opacity(0.45)
        return attributed
    }

    /// ポップアップに出す Action 名
    static func title(for action: SmartAction) -> String {
        switch action {
        case .copy: "コピー"
        case .open: "ブラウザで開く"
        case .markdown: "Markdown リンクをコピー"
        case .explain: "説明する"
        case .search: "Web で検索"
        case .run: "Terminal で実行"
        case .polish: "文章を整える"
        case .shorten: "短くする"
        case .translate: "翻訳する"
        case .newMail: "メールを作成"
        case .openMaps: "マップで開く"
        case .format: "JSON を整形"
        case .inspect: "JSON の構造を見る"
        case .saveImage: "ダウンロードに保存"
        }
    }
}
