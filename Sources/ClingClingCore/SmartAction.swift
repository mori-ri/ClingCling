import Foundation

/// Clipboard Item に対して提示する操作
public enum SmartAction: String, Codable, CaseIterable, Sendable {
    case copy
    case open
    case markdown
    case explain
    case search
    case run
    case polish
    case shorten
    case translate
    case newMail = "new_mail"
    case openMaps = "open_maps"
    case format
    case inspect
    case saveImage = "save_image"
    /// 画像から読み取った文字（OCR）を、画像の代わりにテキストで貼り付ける
    case pasteText = "paste_text"
    /// ファイルを既定のアプリで開く（アプリなら起動、フォルダなら Finder）
    case openFile = "open_file"
    case revealInFinder = "reveal_in_finder"
    case copyPath = "copy_path"
    /// フォルダを新しい Terminal のウインドウで開く
    case openInTerminal = "open_in_terminal"
    /// テキストのファイルの中身をテキストとしてコピーする
    case copyContents = "copy_contents"

    public var title: String {
        switch self {
        case .copy: "Copy"
        case .open: "Open"
        case .markdown: "Markdown"
        case .explain: "Explain"
        case .search: "Search"
        case .run: "Run"
        case .polish: "Polish"
        case .shorten: "Shorten"
        case .translate: "Translate"
        case .newMail: "New Mail"
        case .openMaps: "Open Maps"
        case .format: "Format"
        case .inspect: "Inspect"
        case .saveImage: "Save Image"
        case .pasteText: "Paste as Text"
        case .openFile: "Open File"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        case .openInTerminal: "Open in Terminal"
        case .copyContents: "Copy Contents"
        }
    }

    public var systemImage: String {
        switch self {
        case .copy: "doc.on.doc"
        case .open: "arrow.up.right.square"
        case .markdown: "link"
        case .explain: "questionmark.bubble"
        case .search: "magnifyingglass"
        case .run: "terminal"
        case .polish: "sparkles"
        case .shorten: "arrow.down.right.and.arrow.up.left"
        case .translate: "character.bubble"
        case .newMail: "envelope"
        case .openMaps: "map"
        case .format: "curlybraces"
        case .inspect: "list.bullet.indent"
        case .saveImage: "square.and.arrow.down"
        case .pasteText: "text.viewfinder"
        case .openFile: "arrow.up.forward.app"
        case .revealInFinder: "folder"
        case .copyPath: "character.cursor.ibeam"
        case .openInTerminal: "terminal"
        case .copyContents: "text.alignleft"
        }
    }

    /// 指示を付けて本文を AI（Claude / ChatGPT のアプリや Web）に渡す操作
    public var usesAI: Bool {
        switch self {
        case .explain, .polish, .shorten, .translate: true
        default: false
        }
    }

    /// 本文が Mac の外（AI / 検索エンジン）に出る操作。
    /// `externalAllowed == false` の Item では提示しない。
    public var sendsContentExternally: Bool {
        usesAI || self == .search
    }

    /// 実行の前に内容を確認してもらう操作。
    /// コピーした文字列は他人が用意したものかもしれない。`file:` や `vscode:` はアプリやスクリプトを起動できるので、
    /// Web を開くだけの http(s) 以外は確認する。判定できない URL は確認する側に倒す。
    /// ファイルは、アプリ・インストーラ・スクリプトを含むときと、まとめて開く数が多いときに確認する。
    public func needsConfirmation(for content: String) -> Bool {
        switch self {
        case .run:
            return true
        case .openFile:
            let paths = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return paths.count > FileKind.maxOpenWithoutConfirmation
                || paths.contains { FileKind.classify(path: $0).launchesCode }
        case .open:
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.hasPrefix("www.") { return false }
            guard let scheme = URL(string: text)?.scheme else { return true }
            return !["http", "https"].contains(scheme)
        default:
            return false
        }
    }
}
