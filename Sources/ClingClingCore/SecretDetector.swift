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

/// 完全ローカルで動く Secret Detector（仕様 §16）
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
            rule("Password Assignment",
                 #"(?i)\b(?:password|passwd|pwd|secret|api[_\-]?key|access[_\-]?token|auth[_\-]?token|client[_\-]?secret)\s*[=:]\s*['"]?[^\s'"]{6,}"#),
            rule("Sensitive URL Parameter",
                 #"(?i)[?&#](?:token|access_token|id_token|refresh_token|api_?key|key|secret|password|sig|signature|code|auth)=[^&\s]{8,}"#),
            rule("Email Address", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, .personal),
            rule("Phone Number", #"(?<![\d\-])(?:\+81[\- ]?|0)\d{1,4}[\- ]\d{1,4}[\- ]\d{3,4}(?![\d\-])"#, .personal),
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
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    /// 未知フォーマットの Token 対策。長くランダムに見える文字列を `highEntropy` とする。
    private func entropyFindings(in text: String, excluding existing: [SecretFinding]) -> [SecretFinding] {
        let ns = NSRange(text.startIndex..., in: text)
        return Self.tokenRegex.matches(in: text, range: ns).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            if existing.contains(where: { $0.range.overlaps(range) }) { return nil }
            let token = String(text[range])
            guard Self.looksRandom(token) else { return nil }
            return SecretFinding(kind: .highEntropy, rule: "High Entropy String", range: range)
        }
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
