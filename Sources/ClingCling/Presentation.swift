import AppKit
import ClingClingCore
import SwiftUI
import UniformTypeIdentifiers

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
        case .file: "doc"
        case .other: "doc"
        }
    }

    static func icon(for kind: FileKind) -> String {
        switch kind {
        case .folder: "folder"
        case .application: "app"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .archive: "archivebox"
        case .diskImage: "externaldrive"
        case .installer: "shippingbox"
        case .script: "terminal"
        case .audio: "waveform"
        case .video: "film"
        case .other: "doc"
        case .mixed: "doc.on.doc"
        }
    }

    /// 設定のピン留めの一覧の「種類」の列
    static func kindName(_ item: ClipItem) -> String {
        switch item.contentType {
        case .text: String(localized: "テキスト")
        case .url: String(localized: "リンク")
        case .code: String(localized: "コード")
        case .command: String(localized: "コマンド")
        case .error: String(localized: "エラー")
        case .email: String(localized: "メールアドレス")
        case .address: String(localized: "住所")
        case .json: String(localized: "JSON") // no-l10n
        case .credential: String(localized: "認証情報")
        case .verificationCode: String(localized: "認証コード")
        case .image: String(localized: "画像")
        case .file: String(localized: "ファイル")
        case .other: String(localized: "その他")
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
        if let kind = item.fileKind { return icon(for: kind) }
        return item.sensitivity >= .suspicious ? "lock" : icon(for: item.contentType)
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
    static func confirmationTitle(for action: SmartAction, item: ClipItem) -> String {
        action == .open ? String(localized: "リンクを開く") : title(for: action, item: item)
    }

    /// Item に合わせた Action 名。ファイルを開く操作は、種類や開くアプリで言い方を変える。
    static func title(for action: SmartAction, item: ClipItem) -> String {
        guard action == .openFile, let kind = item.fileKind else { return title(for: action) }
        let paths = item.filePaths
        if paths.count > 1 { return String(localized: "まとめて開く") }
        switch kind {
        case .folder: return String(localized: "Finder で開く")
        case .application: return String(localized: "起動する")
        case .archive: return String(localized: "展開する")
        case .diskImage: return String(localized: "マウントする")
        case .installer: return String(localized: "インストーラを開く")
        default:
            // 既定のアプリの名前を出す（「プレビューで開く」）。分からなければ「開く」。
            // ファイルには触れず拡張子で調べる（デスクトップなどのフォルダへのアクセスの確認を出さないため）
            let ext = (CopiedFiles.plainPath(paths.first ?? "") as NSString).pathExtension
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: type)
            else { return title(for: action) }
            return String(localized: "\(FileManager.default.displayName(atPath: app.path)) で開く")
        }
    }

    /// ファイルを開く前の確認の説明
    static func openFileWarning(_ item: ClipItem) -> String {
        if item.filePaths.contains(where: { FileKind.classify(path: $0).launchesCode }) {
            return String(localized: "アプリの起動やインストール、スクリプトの実行につながるファイルです。心当たりがあるファイルか確認してください。")
        }
        return String(localized: "\(item.filePaths.count) 個のファイルをまとめて開きます。")
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
        case .openFile: String(localized: "開く")
        case .revealInFinder: String(localized: "Finder で表示")
        case .copyPath: String(localized: "パスをコピー")
        case .openInTerminal: String(localized: "Terminal で開く")
        case .copyContents: String(localized: "中身をテキストでコピー")
        }
    }
}
