import Foundation
import Testing
@testable import ClingClingCore

struct SearchTests {
    func make(_ content: String, type: ContentType = .text, source: SourceApp = .unknown, at date: Date = Date()) -> ClipItem {
        ClipItem(createdAt: date, content: content, contentHash: ContentHash.sha256(content), contentType: type,
                 source: source, sensitivity: .normal, retention: .normal, externalAllowed: true,
                 expiresAt: nil, reasons: [])
    }

    @Test func findsJapaneseText() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("来週の会議の議題"))
        try store.save(make("hello world"))
        #expect(try store.recent(query: "会議").map(\.content) == ["来週の会議の議題"])
    }

    @Test func ignoresKanaAndWidthDifferences() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("クリップボード"))
        try store.save(make("ＡＢＣ株式会社"))
        try store.save(make("ｶﾀｶﾅ"))
        #expect(try store.recent(query: "くりっぷ").map(\.content) == ["クリップボード"])
        #expect(try store.recent(query: "abc").map(\.content) == ["ＡＢＣ株式会社"])
        #expect(try store.recent(query: "かたかな").map(\.content) == ["ｶﾀｶﾅ"])
    }

    @Test func ignoresCaseOutsideASCII() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("Ärger im Büro"))
        #expect(try store.recent(query: "ärger").count == 1)
    }

    @Test func allTermsMustMatch() throws {
        let store = try ClipStore(path: nil)
        let now = Date()
        try store.save(make("東京 会議 資料", at: now))
        try store.save(make("東京 ランチ", at: now.addingTimeInterval(1)))
        #expect(try store.recent(query: "東京　会議").map(\.content) == ["東京 会議 資料"])
        #expect(try store.recent(query: "東京").count == 2)
    }

    @Test func matchesSourceNameAndType() throws {
        let store = try ClipStore(path: nil)
        try store.save(make("https://example.com", type: .url))
        try store.save(make("memo", source: SourceApp(bundleID: "com.apple.Safari", name: "Safari")))
        #expect(try store.recent(query: "url").map(\.content) == ["https://example.com"])
        #expect(try store.recent(query: "safari").map(\.content) == ["memo"])
    }

    @Test func highlightRangesMapBackToOriginalText() {
        let text = "メモ: クリップボードの履歴"
        let ranges = SearchQuery("くりっぷ").ranges(in: text)
        #expect(ranges.map { String(text[$0]) } == ["クリップ"])

        let halfwidth = "ｸﾘｯﾌﾟ と ABC"
        #expect(SearchQuery("クリップ abc").ranges(in: halfwidth).map { String(halfwidth[$0]) } == ["ｸﾘｯﾌﾟ", "ABC"])
    }
}

struct RedactionTests {
    let gate = PrivacyGate()
    let detector = SecretDetector()

    func capture(_ text: String) -> ClipItem? {
        let input = CaptureInput(text: text, pasteboardTypes: ["public.utf8-plain-text"],
                                 source: SourceApp(bundleID: "com.apple.Safari", name: "Safari"))
        if case .capture(let item) = gate.evaluate(input, settings: PrivacySettings()) { return item }
        return nil
    }

    @Test(arguments: [
        "https://github.com/mori-ri/ClingCling/blob/main/README.md",
        "https://developer.apple.com/documentation/SwiftUI/View/onGeometryChange",
        "https://www.amazon.co.jp/dp/B0CHX1W1XY/ref=sr_1_3?keywords=MacBookPro2024",
        "See [README](https://github.com/mori-ri/ClingCling/blob/main/Sources/ClingClingCore/PrivacyGate.swift) for details",
        "- `Sources/ClingClingCore/PrivacyGate.swift` の判定を見直す",
        "## ClaudeCodeTipsAndTricks\n\n- [記事](https://zenn.dev/someone/articles/2024ClaudeCodeTips)",
    ])
    func ordinaryURLsAndMarkdownAreNotSuspicious(_ text: String) throws {
        let item = try #require(capture(text))
        #expect(item.sensitivity == .normal)
        #expect(detector.redact(text) == text)
    }

    // ドキュメント ID や追跡用のパラメータは秘密とは限らないので伏せない。外部送信は不可のまま
    @Test(arguments: [
        "https://docs.google.com/document/d/1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdEF/edit",
        "https://www.figma.com/design/Zq8vT2xLm9Rk4PwY7nB3cJ/Design?node-id=1-2",
        "https://example.com/article?fbclid=IwAR3xKq9Lm2ZpQ7rWt5YnB8cJd4FhS1g",
    ])
    func randomIDsInAURLAreNotMasked(_ url: String) throws {
        let item = try #require(capture(url))
        #expect(item.sensitivity == .suspicious)
        #expect(item.contentType == .url)
        #expect(item.externalAllowed == false)
        #expect(!item.isFullyMasked)
        #expect(item.rowText(detector: detector) == url)
        #expect(detector.redact(url) == url)
    }

    @Test func randomIDsInAURLInsideTextAreNotMasked() {
        let text = "資料はこちら https://docs.google.com/document/d/1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdEF/edit です"
        #expect(detector.redact(text) == text)
        // URL の外にある Token は伏せる
        let token = "Zq8vT2xLm9Rk4PwY7nB3cJ6hF1dS5gA0 https://example.com"
        #expect(detector.redact(token) == "Zq8v••••••••5gA0 https://example.com")
    }

    // URL のパラメータやパスワードの値だけを伏せ、URL の残りは読めるようにする
    @Test(arguments: [
        ("https://example.com/callback?code=abcdefgh12345678&state=x",
         "https://example.com/callback?code=abcd••••••••5678&state=x"),
        ("https://user:hunter2pass@example.com/path", "https://user:••••••••@example.com/path"),
        // GitHub の Secret Scanning に本物の Webhook と誤認されないよう、ホスト名を分けて組み立てる
        ("https://hooks." + "slack.com/services/T0123ABCD/B0456EFGH/abcdefghijklmnopqrstuvwx",
         "https://hooks." + "slack.com/services/T0123ABCD/B0456EFGH/abcd••••••••uvwx"),
    ])
    func onlyTheSecretValueOfAURLIsMasked(_ url: String, _ shown: String) throws {
        let item = try #require(capture(url))
        #expect(item.contentType == .url)
        #expect(item.sensitivity == .secret)
        #expect(item.isTemporary)
        #expect(!item.isFullyMasked)
        #expect(item.rowText(detector: detector) == shown)
        #expect(item.fullText(limit: 1_000, detector: detector) == shown)
    }

    @Test func aURLWithAKnownSecretIsFullyMasked() throws {
        let url = "https://example.com/?q=ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let item = try #require(capture(url))
        #expect(item.isFullyMasked)
    }

    @Test func randomTokensAreStillDetected() {
        #expect(SecretDetector.looksRandom("Zq8vT2xLm9Rk4PwY7nB3cJ6hF1dS5gA0"))
        // `/` を含む Base64 も、区切りごとではなく全体で判定される
        #expect(!detector.scan("aB3/xK9q/Lm2Z/pQ7r/Wt5Y/nB8c/Jd4F/hS1g").isEmpty)
        #expect(!detector.scan("3f2a9c1e5b7d4f6a8c0e2b4d6f8a1c3e5b7d9f0a").isEmpty)
    }

    @Test func redactKeepsSurroundingText() {
        let text = "トークンは Zq8vT2xLm9Rk4PwY7nB3cJ6hF1dS5gA0 です。連絡先 mori@example.com"
        #expect(detector.redact(text) == "トークンは Zq8v••••••••5gA0 です。連絡先 mori@example.com")
    }
}

struct BackupExclusionTests {
    @Test func historyDirectoryIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClingCling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try ClipStore(path: directory.appendingPathComponent("clingcling.sqlite"))

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

struct ClipDisplayTests {
    let detector = SecretDetector()
    let token = "aB3xK9mQ2vL7nR4tY8pZ1wC6"

    func make(_ content: String, type: ContentType = .text, sensitivity: Sensitivity = .normal) -> ClipItem {
        ClipItem(createdAt: Date(), content: content, contentHash: ContentHash.sha256(content), contentType: type,
                 source: .unknown, sensitivity: sensitivity, retention: .normal, externalAllowed: false,
                 expiresAt: nil, reasons: [])
    }

    @Test func fullTextKeepsEveryLine() {
        let text = (1...10).map { "行 \($0)" }.joined(separator: "\n")
        #expect(make(text).fullText(limit: 1_000, detector: detector) == text)
    }

    @Test func fullTextNeverShowsLaterLinesOfASecret() {
        let item = make("-----BEGIN PRIVATE KEY-----\na\nb\nc\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----",
                        sensitivity: .secret)
        let text = item.fullText(limit: 1_000, detector: detector)
        #expect(!text.contains("MIIEvQ"))
        #expect(text == item.rowText(detector: detector))
    }

    @Test func fullTextRedactsTokensOnEveryLine() {
        let item = make("1\n2\n3\n4\nid: \(token)\n末尾", sensitivity: .suspicious)
        let text = item.fullText(limit: 1_000, detector: detector)
        #expect(!text.contains(token))
        #expect(text.hasSuffix("\n末尾"))
    }

    @Test func fullTextDropsTokenCutByTheLimit() {
        let item = make("\(String(repeating: "あ", count: 10)) \(token)", sensitivity: .suspicious)
        let text = item.fullText(limit: 21, detector: detector)
        #expect(text == "\(String(repeating: "あ", count: 10)) ")
    }

    @Test func fullTextCutOnlyWhenLongerThanLimit() {
        #expect(make("12345").isFullTextCut(limit: 5) == false)
        #expect(make("123456").isFullTextCut(limit: 5))
        // 全体を伏せる Item は切らずに伏せる
        #expect(make(String(repeating: "x", count: 10), sensitivity: .secret).isFullTextCut(limit: 5) == false)
    }

    @Test func fullTextShowsVerificationCode() {
        let item = make("認証コード 123456", type: .verificationCode, sensitivity: .secret)
        #expect(item.fullText(limit: 1_000, detector: detector) == "認証コード 123456")
    }
}
