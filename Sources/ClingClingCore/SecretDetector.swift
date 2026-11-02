import Foundation

/// Secret 検出結果
public struct SecretFinding: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// 既知フォーマットの Secret（正規表現一致）
        case knownSecret
        /// 未知フォーマットの高エントロピー文字列
        case highEntropy
        /// 個人情報（メールアドレス・電話番号）
        case personal
    }

    public var kind: Kind
    public var rule: String
    /// 一致した範囲（UI でのマスク表示に使う）
    public var range: Range<String.Index>
}

/// 完全ローカルで動く Secret Detector
public struct SecretDetector: Sendable {
    struct Rule: Sendable {
        let name: String
        let regex: NSRegularExpression
        let kind: SecretFinding.Kind
    }

    let rules: [Rule]

    public init() {
        func rule(_ name: String, _ pattern: String, _ kind: SecretFinding.Kind = .knownSecret) -> Rule {
            // パターンは静的なので失敗したら即座に気付けるようにする
            Rule(name: name, regex: try! NSRegularExpression(pattern: pattern), kind: kind)
        }
        rules = [
            rule("AWS Access Key", #"\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b"#),
            rule("AWS Secret Key", #"(?i)aws_?secret_?access_?key\s*[=:]\s*\S+"#),
            rule("GitHub Token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#),
            rule("GitHub Fine-grained Token", #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#),
            rule("Anthropic API Key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
            rule("OpenAI API Key", #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#),
            rule("Slack Token", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
            rule("Google API Key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
            rule("Stripe Key", #"\b(?:sk|rk|pk)_(?:live|test)_[0-9A-Za-z]{16,}"#),
            rule("Bearer Token", #"(?i)\bbearer\s+[A-Za-z0-9\-._~+/]{16,}=*"#),
            rule("JWT", #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
            rule("Private Key", #"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----"#),
            rule("Certificate", #"-----BEGIN CERTIFICATE-----"#),
            rule("Credentials in URL", #"(?i)\b[a-z][a-z0-9+.\-]*://[^\s:/@]+:[^\s@/]+@"#),
            // `DB_PASSWORD=…`（前に語が付く形）や `{"password": "…"}`（キーが引用符で閉じる形）も対象にする。
            // `token` だけの語は変数名として多いので、`GITHUB_TOKEN` のように区切りが付くものに限る。
            rule("Password Assignment",
                 #"(?i)(?:password|passwd|pwd|secret|api[_\-]?key|private[_\-]?key|[_\-]token|accesstoken|authtoken)(?:\\?["'])?\s*[=:]\s*(?:\\?['"])?[^\s'"\\]{6,}"#),
            // 値は ASCII に限る。「パスワードは忘れないように」のような文章を Secret にしないため。
            rule("Password Assignment",
                 #"(?:パスワード|パスコード|シークレット|秘密鍵|API ?キー|アクセスキー|アクセストークン)\s*(?:[:：=＝]|は)\s*[「『"']?[!-~]{4,}"#), // no-l10n
            rule("PIN", #"暗証番号\s*(?:[:：=＝は]\s*)?[0-9０-９]{4,}"#), // no-l10n
            rule("Sensitive URL Parameter",
                 #"(?i)[?&#](?:token|access_token|id_token|refresh_token|api_?key|key|secret|password|sig|signature|code|auth)=[^&\s]{8,}"#),
            rule("Email Address", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, .personal),
            rule("Phone Number", #"(?<![\d\-])(?:\+81[\- ]?|0)\d{1,4}[\- ]\d{1,4}[\- ]\d{3,4}(?![\d\-])"#, .personal),
            // 区切りのない携帯電話番号。固定電話の 10 桁は他の数字と区別できないので対象にしない。
            rule("Phone Number", #"(?<![\d\-])(?:\+81|0)[789]0\d{8}(?![\d\-])"#, .personal),
        ]
    }

    public func scan(_ text: String) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        let ns = NSRange(text.startIndex..., in: text)
        for rule in rules {
            for match in rule.regex.matches(in: text, range: ns) {
                guard let range = Range(match.range, in: text) else { continue }
                findings.append(SecretFinding(kind: rule.kind, rule: rule.name, range: range))
            }
        }
        findings += creditCardFindings(in: text)
        findings += entropyFindings(in: text, excluding: findings)
        return findings
    }

    // MARK: - Credit card (Luhn)

    private static let cardRegex = try! NSRegularExpression(pattern: #"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)"#)

    private func creditCardFindings(in text: String) -> [SecretFinding] {
        let ns = NSRange(text.startIndex..., in: text)
        return Self.cardRegex.matches(in: text, range: ns).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let digits = text[range].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count), Self.luhn(digits) else { return nil }
            return SecretFinding(kind: .knownSecret, rule: "Credit Card", range: range)
        }
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Entropy

    private static let tokenRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/=_\-.~]{20,}"#)
    private static let camelWordsRegex = try! NSRegularExpression(
        pattern: #"^(?:[A-Z]?[a-z]{2,}|[A-Z]{2,}(?![a-z])|[0-9]+|[\-_=.~+])+$"#)
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    /// 未知フォーマットの Token 対策。長くランダムに見える文字列を `highEntropy` とする。
    private func entropyFindings(in text: String, excluding existing: [SecretFinding]) -> [SecretFinding] {
        let ns = NSRange(text.startIndex..., in: text)
        return Self.tokenRegex.matches(in: text, range: ns).flatMap { match -> [SecretFinding] in
            guard let range = Range(match.range, in: text) else { return [] }
            if existing.contains(where: { $0.range.overlaps(range) }) { return [] }
            return Self.randomRanges(in: text, token: range).map {
                SecretFinding(kind: .highEntropy, rule: "High Entropy String", range: $0)
            }
        }
    }

    /// Token の中でランダムに見える範囲。
    ///
    /// URL やファイルパス（`//github.com/owner/Repo/blob/main/README.md`）は `/` 区切りの単語の並びなので、
    /// 全体を 1 つの Token として見ると長さと文字種だけで「ランダム」と誤判定してしまう。
    /// `/` を含むときは区切りごとに判定し、ランダムに見える区切り（ドキュメント ID など）だけを返す。
    static func randomRanges(in text: String, token range: Range<String.Index>) -> [Range<String.Index>] {
        let token = text[range]
        guard token.contains("/") else { return looksRandom(String(token)) ? [range] : [] }

        var segments: [Range<String.Index>] = []
        var start = range.lowerBound
        for index in token.indices where token[index] == "/" {
            if start < index { segments.append(start..<index) }
            start = token.index(after: index)
        }
        if start < range.upperBound { segments.append(start..<range.upperBound) }

        let random = segments.filter { text[$0].count >= 16 && looksRandom(String(text[$0])) }
        if !random.isEmpty { return random }
        // 区切りが短いだけの Base64 などは、単語の並びより文字種が頻繁に入れ替わる。そのときは全体で判定する。
        guard classSwitchRatio(token) >= 0.45 else { return [] }
        return looksRandom(String(token)) ? [range] : []
    }

    /// 英数字だけを見たとき、隣り合う文字の種類（大文字・小文字・数字）が入れ替わる割合。
    /// ランダムな Base62 / Base64 は 0.6 前後、単語やパスは 0.3 以下になりやすい。
    static func classSwitchRatio(_ s: Substring) -> Double {
        func kind(_ c: Character) -> Int { c.isUppercase ? 0 : c.isLowercase ? 1 : 2 }
        let chars = s.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard chars.count > 1 else { return 0 }
        var switches = 0
        var previous = kind(chars[chars.startIndex])
        for c in chars.dropFirst() {
            let k = kind(c)
            if k != previous { switches += 1 }
            previous = k
        }
        return Double(switches) / Double(chars.count - 1)
    }

    // MARK: - Redaction

    /// Secret / ランダムな Token の部分だけを伏せた文字列（一覧表示用）。個人情報は伏せない。
    public func redact(_ text: String) -> String {
        let ranges = SearchQuery.merged(scan(text).filter { $0.kind != .personal }.map(\.range))
        guard !ranges.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            result += text[cursor..<range.lowerBound]
            result += Self.mask(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// 先頭と末尾 4 文字だけを残して伏せる。短いものは全部伏せる。
    public static func mask(_ text: String) -> String {
        let compact = text.trimmingCharacters(in: .whitespaces)
        guard compact.count > 12 else { return String(repeating: "•", count: 8) }
        return "\(compact.prefix(4))••••••••\(compact.suffix(4))"
    }

    static func looksRandom(_ token: String) -> Bool {
        let tokenNS = NSRange(token.startIndex..., in: token)
        if uuidRegex.firstMatch(in: token, range: tokenNS) != nil { return false }
        // ドメイン名やファイルパスのような「.区切りの単語」は除外
        if token.contains("."), token.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isLetter) || $0.count < 12 }) {
            return false
        }

        let hasDigit = token.contains(where: \.isNumber)
        let hasLower = token.contains(where: \.isLowercase)
        let hasUpper = token.contains(where: \.isUppercase)
        let isHex = token.allSatisfy(\.isHexDigit)

        // 長い Hex（ハッシュ・鍵）。Git の SHA なども含まれるが、Fail Closed のため外部送信不可側に倒す。
        if isHex { return token.count >= 32 && hasDigit }

        // CamelCase の識別子や URL の語（MacBookPro2024 / ClingClingCoreTests）は「大文字 + 小文字 2 文字以上」の単語の並び。
        // 大小混在のランダムな文字列がこの形になる確率は 20 文字で 1% 未満なので、単語の並びとみなして除外する。
        if hasUpper, hasLower, camelWordsRegex.firstMatch(in: token, range: tokenNS) != nil { return false }

        let classes = [hasDigit, hasLower, hasUpper].filter { $0 }.count
        guard classes >= 2, hasDigit || token.count >= 32 else { return false }
        return shannonEntropy(token) >= (token.count >= 40 ? 4.0 : 3.6)
    }

    public static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0) { acc, count in
            let p = Double(count) / n
            return acc - p * log2(p)
        }
    }
}
