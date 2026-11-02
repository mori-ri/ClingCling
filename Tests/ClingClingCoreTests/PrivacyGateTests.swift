import Foundation
import Testing
@testable import ClingClingCore

struct PrivacyGateTests {
    let gate = PrivacyGate()
    let settings = PrivacySettings()
    let terminal = SourceApp(bundleID: "com.apple.Terminal", name: "Terminal")

    func capture(_ text: String, types: Set<String> = ["public.utf8-plain-text"], source: SourceApp? = nil) -> ClipItem? {
        let input = CaptureInput(text: text, pasteboardTypes: types, source: source ?? terminal)
        if case .capture(let item) = gate.evaluate(input, settings: settings) { return item }
        return nil
    }

    // Password Manager からのコピーは保存も外部送信もしない
    @Test func dropsPasswordManagerCopies() {
        #expect(capture("hunter2-correct-horse", source: SourceApp(bundleID: "com.1password.1password", name: "1Password")) == nil)
        #expect(capture("hunter2", source: SourceApp(bundleID: nil, name: "Bitwarden")) == nil)
    }

    @Test func dropsConcealedAndTransientMarkers() {
        #expect(capture("secret", types: [PrivacyGate.concealedType, "public.utf8-plain-text"]) == nil)
        #expect(capture("secret", types: [PrivacyGate.transientType]) == nil)
    }

    @Test func respectsAppPolicies() {
        var s = settings
        s.appPolicies = ["com.example.corp": .neverCapture, "com.example.local": .localOnly]
        let never = gate.evaluate(CaptureInput(text: "hello", pasteboardTypes: [], source: SourceApp(bundleID: "com.example.corp", name: nil)), settings: s)
        #expect(never == .drop(reason: "app policy: never capture"))

        guard case .capture(let item) = gate.evaluate(
            CaptureInput(text: "hello world", pasteboardTypes: [], source: SourceApp(bundleID: "com.example.local", name: nil)), settings: s)
        else { Issue.record("expected capture"); return }
        #expect(item.externalAllowed == false)
    }

    @Test(arguments: [
        "AKIAIOSFODNN7EXAMPLE",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
        "postgres://admin:s3cretPass@db.example.com:5432/app",
        "4111 1111 1111 1111",
    ])
    func knownSecretsAreTemporaryAndLocalOnly(_ secret: String) throws {
        let item = try #require(capture(secret))
        #expect(item.sensitivity == .secret)
        #expect(item.externalAllowed == false)
        #expect(item.retention == .temporary)
        #expect(item.expiresAt != nil)
    }

    @Test(arguments: [
        "POSTGRES_PASSWORD=hunter2hunter",
        "DB_PASSWORD=abc123xyz",
        "export MY_API_KEY=abc12345",
        "APP_SECRET=abc12345xyz",
        "GITHUB_TOKEN=abc12345xyz",
        "spring.datasource.password=abc123xyz",
        "{\"password\": \"hunter2hunter\"}",
        "{\"api_key\":\"abcd1234efgh\"}",
        "{\\\"password\\\": \\\"hunter2hunter\\\"}",
        "password: \"hunter2hunter\"",
        "パスワード: hunter2",
        "パスワード：hunter2",
        "パスワードは hunter2 です",
        "暗証番号 1234",
        "暗証番号は１２３４です",
    ])
    func secretAssignmentsAreTemporaryAndLocalOnly(_ text: String) throws {
        let item = try #require(capture(text))
        #expect(item.sensitivity == .secret)
        #expect(item.externalAllowed == false)
        #expect(item.retention == .temporary)
    }

    // 誤検出すると、普通の文章やコードが履歴に残らず AI にも渡せなくなる
    @Test(arguments: [
        "パスワードは忘れないようにしてください",
        "パスワードは8文字以上にしてください",
        "secretary: Alice Smith",
        "max_tokens: 1000000",
        "let token = try await fetchToken()",
        "password: 必須",
    ])
    func textAboutSecretsIsNotASecret(_ text: String) throws {
        let item = try #require(capture(text))
        #expect(item.sensitivity == .normal)
        #expect(item.externalAllowed == true)
    }

    @Test(arguments: ["09012345678", "+818012345678", "連絡先は 07012345678 です"])
    func mobileNumbersWithoutSeparatorsAreLocalOnly(_ text: String) throws {
        let item = try #require(capture(text))
        #expect(item.sensitivity == .personal)
        #expect(item.externalAllowed == false)
    }

    @Test func unknownHighEntropyTokenIsLocalOnly() throws {
        let item = try #require(capture("Zq8vT2xLm9Rk4PwY7nB3cJ6hF1dS5gA0"))
        #expect(item.sensitivity == .suspicious)
        #expect(item.contentType == .credential)
        #expect(item.externalAllowed == false)
        // 未知の Token は保存はするが外部送信しない
        #expect(item.retention == .normal)
    }

    @Test func verificationCodeIsTemporary() throws {
        let item = try #require(capture("824913"))
        #expect(item.contentType == .verificationCode)
        #expect(item.retention == .temporary)
        #expect(item.externalAllowed == false)
    }

    @Test func secretInsideSentenceKeepsTextTypeButLocalOnly() throws {
        let item = try #require(capture("API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123 を設定してください。設定後に再起動が必要です。"))
        #expect(item.externalAllowed == false)
        #expect(item.sensitivity == .secret)
    }

    @Test func personalInfoIsLocalOnly() throws {
        let item = try #require(capture("来週の件、mori@example.com まで連絡ください"))
        #expect(item.sensitivity == .personal)
        #expect(item.externalAllowed == false)
        #expect(item.retention == .normal)
    }

    @Test func plainErrorIsExternallyEligible() throws {
        let item = try #require(capture("An error occurred (AccessDeniedException) when calling the Invoke operation"))
        #expect(item.contentType == .error)
        #expect(item.sensitivity == .normal)
        #expect(item.externalAllowed == true)
    }

    @Test func urlWithTokenParameterIsLocalOnly() throws {
        let item = try #require(capture("https://example.com/callback?code=abcdefgh12345678&state=x"))
        #expect(item.contentType == .url)
        #expect(item.externalAllowed == false)
    }

    @Test func gitShaIsNotSentExternally() throws {
        let item = try #require(capture("3f2a9c1e5b7d4f6a8c0e2b4d6f8a1c3e5b7d9f0a"))
        #expect(item.externalAllowed == false)
    }

    @Test func ordinaryProseIsEligible() throws {
        let item = try #require(capture("来週の会議についてですが、議題を少し整理してから共有します。"))
        #expect(item.contentType == .text)
        #expect(item.externalAllowed == true)
    }

    // 画像は中身を検査できないので、保存はしても外部送信は不可
    @Test func imagesAreCapturedButLocalOnly() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let input = CaptureInput(image: ImageCapture(png: png, width: 640, height: 480),
                                 pasteboardTypes: ["public.png"], source: terminal)
        guard case .capture(let item) = gate.evaluate(input, settings: settings) else {
            Issue.record("expected capture"); return
        }
        #expect(item.contentType == .image)
        #expect(item.externalAllowed == false)
        #expect(item.retention == .normal)
        #expect(item.image == ClipImage(fileName: ContentHash.sha256(png) + ".png", width: 640, height: 480))
    }

    @Test func imagesRespectMarkersAndPasswordManagers() {
        let image = ImageCapture(png: Data([1, 2, 3]), width: 1, height: 1)
        let concealed = CaptureInput(image: image, pasteboardTypes: [PrivacyGate.concealedType], source: terminal)
        #expect(gate.evaluate(concealed, settings: settings) == .drop(reason: "concealed pasteboard marker"))
        let fromVault = CaptureInput(image: image, pasteboardTypes: ["public.png"],
                                     source: SourceApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden"))
        #expect(gate.evaluate(fromVault, settings: settings) == .drop(reason: "password manager"))
    }
}
