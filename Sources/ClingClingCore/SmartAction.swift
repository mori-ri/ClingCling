import Foundation

/// Clipboard Item に対して提示する操作（仕様 §8）
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
}
