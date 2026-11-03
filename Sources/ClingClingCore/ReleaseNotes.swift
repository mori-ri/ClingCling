import Foundation

/// お知らせのページに描くリリースノートの 1 行。文字はインラインの Markdown（太字、リンク）のまま持ち、
/// `ReleaseNotes.inline` で描く。
public enum ReleaseNoteBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    /// 箇条書きの 1 項目。`marker` は箇条書きなら "•"、番号付きならその番号（"1."）。
    case item(marker: String, text: String, level: Int)
}

/// 公開済みのリリースと、そこで変わったこと
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    public let version: AppVersion
    public let publishedAt: Date?
    public let blocks: [ReleaseNoteBlock]

    public var id: String { version.text }

    public init(version: AppVersion, publishedAt: Date?, blocks: [ReleaseNoteBlock]) {
        self.version = version
        self.publishedAt = publishedAt
        self.blocks = blocks
    }
}

/// GitHub のリリースの本文（Markdown）を、お知らせのページの部品に分ける。
///
/// 本文はリリースのページ向けに書いているので、そこでしか意味のない部分は捨てる:
/// インストールの節（アプリには専用のダウンロードボタンがある）、コードブロック、Full Changelog の行。
public enum ReleaseNotes {
    /// 本文は数 KB。それよりずっと大きいものは並べずに切る。
    static let maxLength = 20_000

    public static func blocks(from markdown: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        var paragraph: [String] = []
        var inCode = false
        /// 読み飛ばしている節の見出しのレベル
        var skippingBelow: Int?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        let text = String(markdown.prefix(maxLength)).replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                inCode.toggle()
                continue
            }
            if inCode { continue }

            if let header = heading(trimmed) {
                flush()
                if let skip = skippingBelow, header.level > skip { continue }
                skippingBelow = nil
                if isInstallSection(header.title) {
                    skippingBelow = header.level
                } else {
                    blocks.append(.heading(header.title))
                }
                continue
            }
            if skippingBelow != nil { continue }

            if trimmed.isEmpty || isRule(trimmed) || isChangelogLink(trimmed) || isComment(trimmed) {
                flush()
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            if trimmed.hasPrefix(">") {
                paragraph.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        // 中身のない見出しが末尾に残ったら消す（読み飛ばした節の直前の見出しなど）
        while case .heading(_)? = blocks.last { blocks.removeLast() }
        return blocks
    }

    /// インラインの Markdown を描く。ネットワークから来た文字でファイルや他のアプリの URL スキームを
    /// 開けないよう、押せるリンクは https のものだけにする。
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard var result = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        let unsafe = result.runs.compactMap { run in
            run.link.flatMap { $0.scheme?.lowercased() == "https" ? nil : run.range }
        }
        for range in unsafe { result[range].link = nil }
        return result
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes, title)
    }

    private static func listItem(_ line: String) -> ReleaseNoteBlock? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        let level = min(indent / 2, 2)
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            let text = rest.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .item(marker: "•", text: text, level: level)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if (1...3).contains(digits.count), rest.dropFirst(digits.count).hasPrefix(". ") {
            let text = rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .item(marker: String(digits) + ".", text: text, level: level)
        }
        return nil
    }

    private static func isInstallSection(_ title: String) -> Bool {
        title.contains("インストール") || title.lowercased().contains("install") // no-l10n
    }

    /// `---` などの区切り線
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isChangelogLink(_ line: String) -> Bool {
        line.hasPrefix("**Full Changelog**")
    }

    private static func isComment(_ line: String) -> Bool {
        line.hasPrefix("<!--") && line.hasSuffix("-->")
    }
}
