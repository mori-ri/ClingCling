import Foundation

/// ルールベースのローカル分類器（仕様 §7, §37）。
/// 将来ローカルモデルに置き換えられるよう、入出力は `ContentType` のみに保つ。
public struct ContentClassifier: Sendable {
    public init() {}

    public func classify(_ raw: String) -> ContentType {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .other }

        let lines = text.split(whereSeparator: \.isNewline)
        let singleLine = lines.count == 1

        if Self.matches(Self.verificationCode, text) { return .verificationCode }
        if singleLine, Self.isURL(text) { return .url }
        if singleLine, Self.matches(Self.email, text) { return .email }
        if Self.isJSON(text) { return .json }
        if Self.isError(text) { return .error }
        if lines.count <= 5, Self.isCommand(lines) { return .command }
        if Self.isCode(text, lineCount: lines.count) { return .code }
        if text.count < 200, Self.isAddress(text) { return .address }
        return .text
    }

    // MARK: - Patterns

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static let verificationCode = regex(#"^(?:\d{4,8}|\d{3}[ \-]\d{3}|[A-Z0-9]{3}-[A-Z0-9]{3})$"#)
    private static let email = regex(#"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#)

    static func isURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace) else { return false }
        let candidate = s.lowercased().hasPrefix("www.") ? "https://" + s : s
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return false }
        if ["http", "https"].contains(scheme) { return url.host?.contains(".") == true || url.host == "localhost" }
        return ["ftp", "file", "mailto", "slack", "vscode", "x-apple.systempreferences"].contains(scheme)
    }

    static func isJSON(_ s: String) -> Bool {
        guard let first = s.first, first == "{" || first == "[", s.count > 1,
              let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static let errorPatterns: [NSRegularExpression] = [
        regex(#"\b[A-Z][A-Za-z0-9]*[a-z](?:Exception|Error)\b"#),   // AccessDeniedException, TypeError
        regex(#"(?m)^Traceback \(most recent call last\)"#),
        regex(#"(?im)^\s*(?:error|fatal|panic|exception)(?:\[[\w\-]+\])?\s*:"#),
        regex(#"(?m)^\s*at [\w.$<>]+\(.*:\d+(?::\d+)?\)"#),           // JS / Java stack frame
        regex(#"(?m)^\s*File ".+", line \d+"#),                        // Python frame
        regex(#"(?i)\b(?:command not found|no such file or directory|permission denied|segmentation fault|access denied|unauthorized|forbidden)\b"#),
        regex(#"\bnpm ERR!"#),
        regex(#"(?i)\bexit(?:ed)? (?:code|status) [1-9]\d*"#),
        regex(#"\b(?:4\d{2}|5\d{2}) (?:Bad Request|Unauthorized|Forbidden|Not Found|Internal Server Error|Bad Gateway|Service Unavailable)\b"#),
    ]

    static func isError(_ s: String) -> Bool {
        errorPatterns.contains { matches($0, s) }
    }

    static let knownCommands: Set<String> = [
        "git", "gh", "npm", "npx", "yarn", "pnpm", "node", "bun", "deno", "python", "python3", "pip", "pip3", "uv",
        "brew", "docker", "kubectl", "helm", "aws", "gcloud", "az", "terraform", "cd", "ls", "cat", "curl", "wget",
        "ssh", "scp", "rsync", "make", "swift", "xcodebuild", "xcrun", "cargo", "go", "sudo", "chmod", "chown", "mkdir",
        "rm", "cp", "mv", "grep", "rg", "find", "echo", "export", "open", "defaults", "launchctl", "tail", "head", "ps",
        "kill", "killall", "ping", "java", "mvn", "gradle", "ruby", "gem", "bundle", "rails", "sed", "awk", "jq", "tar",
        "unzip", "zip", "xattr", "codesign", "security", "systemctl", "journalctl", "psql", "mysql", "redis-cli",
        "mongosh", "ffmpeg", "pod", "claude", "touch", "source", "env", "which", "man", "dig", "nslookup", "lsof",
    ]

    static func isCommand(_ lines: [Substring]) -> Bool {
        var line = lines[0].trimmingCharacters(in: .whitespaces)
        for prompt in ["$ ", "% ", "# ", "> "] where line.hasPrefix(prompt) {
            line = String(line.dropFirst(prompt.count))
        }
        guard let first = line.split(separator: " ").first.map(String.init) else { return false }
        if first.hasPrefix("./") || first.hasPrefix("~/") { return true }
        // "VAR=value cmd ..." 形式
        if first.contains("="), let next = line.split(separator: " ").dropFirst().first {
            return knownCommands.contains(String(next))
        }
        return knownCommands.contains(first)
    }

    private static let codeKeyword = regex(
        #"(?m)^\s*(?:func|def|class|struct|enum|interface|import|from \S+ import|const|let|var|public|private|protected|return|fn|package|#include|using|namespace|async function|function|export)\b"#)
    private static let codeSymbols = regex(#"(?m)(?:[;{]\s*$|^\s*\}|=>|\)\s*\{|->\s*\w+|::|\bnil\b|\bnull\b|\bself\.|\bthis\.)"#)

    static func isCode(_ s: String, lineCount: Int) -> Bool {
        let keyword = matches(codeKeyword, s)
        let symbols = codeSymbols.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
        if keyword && (symbols > 0 || lineCount > 1) { return true }
        return symbols >= 3
    }

    private static let addressPatterns: [NSRegularExpression] = [
        regex(#"(?<![\d\-])〒?\d{3}-\d{4}(?![\d\-])"#),
        regex(#"(?:東京都|北海道|(?:京都|大阪)府|[^\s]{2,3}県)[^\s]{1,8}?[市区町村郡].*\d"#),
        regex(#"(?i)\b\d+\s+[\w .]+\b(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Dr|Drive|Ln|Lane|Way)\b.*\b\d{5}\b"#),
    ]

    static func isAddress(_ s: String) -> Bool {
        addressPatterns.contains { matches($0, s) }
    }
}
