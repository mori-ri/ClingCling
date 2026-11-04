import Foundation
import Testing
@testable import ClingClingCore

/// 設定のピン留めのページで本文を書き換えるときの判定と保存
struct PinnedEditTests {
    let gate = PrivacyGate()
    let settings = PrivacySettings()
    let terminal = SourceApp(bundleID: "com.apple.Terminal", name: "Terminal")

    func pinned(_ store: ClipStore, _ text: String, source: SourceApp? = nil) throws -> ClipItem {
        let input = CaptureInput(text: text, pasteboardTypes: [], source: source ?? terminal)
        guard case .capture(let item) = gate.evaluate(input, settings: settings) else {
            Issue.record("expected capture")
            throw CancellationError()
        }
        let saved = try store.save(item)
        try store.setPinned(saved.id, true)
        return try #require(try store.recent().first { $0.id == saved.id })
    }

    func edit(_ store: ClipStore, _ item: ClipItem, to text: String, settings: PrivacySettings? = nil) throws -> ClipStore.ContentUpdate? {
        guard case .accepted(let edited) = gate.evaluateEdit(text, of: item, settings: settings ?? self.settings) else {
            return nil
        }
        return try store.updateContent(item.id, to: edited)
    }

    @Test func rewritesContentAndReclassifies() throws {
        let store = try ClipStore(path: nil)
        let item = try pinned(store, "あとで読む")
        try store.setTitle(item.id, "メモ")
        try store.setFolder(item.id, "仕事")

        #expect(try edit(store, item, to: "https://example.com/docs") == .updated)
        let edited = try #require(try store.recent().first { $0.id == item.id })
        #expect(edited.content == "https://example.com/docs")
        #expect(edited.contentType == .url)
        #expect(edited.contentHash == ContentHash.sha256("https://example.com/docs"))
        // ピン留め・別名・フォルダ・コピー元はそのまま
        #expect(edited.isPinned)
        #expect(edited.title == "メモ")
        #expect(edited.folder == "仕事")
        #expect(edited.source == terminal)
        // 検索も新しい本文に一致する
        #expect(try store.recent(query: "example").map(\.id) == [item.id])
        #expect(try store.recent(query: "あとで").isEmpty)
    }

    @Test(arguments: ["AKIAIOSFODNN7EXAMPLE", "123456"])
    func refusesSecretsAndCodes(_ text: String) throws {
        let store = try ClipStore(path: nil)
        let item = try pinned(store, "メモ")
        #expect(gate.evaluateEdit(text, of: item, settings: settings) == .notSavable)
    }

    @Test func refusesEmptyContent() throws {
        let store = try ClipStore(path: nil)
        let item = try pinned(store, "メモ")
        #expect(gate.evaluateEdit(" \n ", of: item, settings: settings) == .empty)
    }

    @Test func keepsLocalOnlyPolicyOfTheSourceApp() throws {
        var s = settings
        s.appPolicies = ["com.example.local": .localOnly]
        let store = try ClipStore(path: nil)
        let local = SourceApp(bundleID: "com.example.local", name: nil)
        let item = try pinned(store, "社内メモ", source: local)
        guard case .accepted(let edited) = gate.evaluateEdit("社内メモ 2", of: item, settings: s) else {
            Issue.record("expected accepted")
            return
        }
        #expect(edited.externalAllowed == false)
    }

    @Test func refusesDuplicateContent() throws {
        let store = try ClipStore(path: nil)
        let item = try pinned(store, "a")
        _ = try store.save(try #require({
            if case .capture(let other) = gate.evaluate(
                CaptureInput(text: "b", pasteboardTypes: [], source: terminal), settings: settings) { return other }
            return nil
        }()))
        #expect(try edit(store, item, to: "b") == .duplicate)
        #expect(try store.recent().first { $0.id == item.id }?.content == "a")
        // 同じ本文のままなら書き換えたことにする
        #expect(try edit(store, item, to: "a") == .updated)
    }

    @Test func onlyPlainTextIsEditable() throws {
        let store = try ClipStore(path: nil)
        let text = try pinned(store, "メモ")
        #expect(text.isContentEditable)

        let image = ClipItem(createdAt: Date(), content: "画像 2×2", contentHash: "img", contentType: .image,
                             source: .unknown, sensitivity: .normal, retention: .pinned, externalAllowed: false,
                             expiresAt: nil, reasons: [], image: ClipImage(fileName: "img.png", width: 2, height: 2))
        #expect(!image.isContentEditable)

        let file = ClipItem(createdAt: Date(), content: "/tmp/a.txt", contentHash: "file", contentType: .file,
                            source: .unknown, sensitivity: .normal, retention: .pinned, externalAllowed: false,
                            expiresAt: nil, reasons: [])
        #expect(!file.isContentEditable)

        // 伏せて表示する Item は、編集欄で本文が読めてしまうので書き換えさせない
        var masked = text
        masked.sensitivity = .suspicious
        #expect(!masked.isContentEditable)

        // 画像やファイルの行は書き換えない
        let savedImage = try store.save(image, imageData: Data([0x89]))
        guard case .accepted(let edited) = gate.evaluateEdit("ほかの文字", of: savedImage, settings: settings) else {
            Issue.record("expected accepted")
            return
        }
        #expect(try store.updateContent(savedImage.id, to: edited) == .unavailable)
    }

    @Test func reportsDeletedItemsAsUnavailable() throws {
        let store = try ClipStore(path: nil)
        let item = try pinned(store, "メモ")
        guard case .accepted(let edited) = gate.evaluateEdit("ほかの文字", of: item, settings: settings) else {
            Issue.record("expected accepted")
            return
        }
        try store.delete(item.id)
        #expect(try store.updateContent(item.id, to: edited) == .unavailable)
    }

    @Test func refusesSecretsInNames() throws {
        #expect(PinFolders.containsSecret("AKIAIOSFODNN7EXAMPLE"))
        #expect(PinFolders.containsSecret("password=hunter22"))
        #expect(!PinFolders.containsSecret("社内 Wiki"))
        // メールアドレスなどの個人情報は名前に使ってよい
        #expect(!PinFolders.containsSecret("mori@example.com"))

        let store = try ClipStore(path: nil)
        let item = try pinned(store, "メモ")
        try store.setTitle(item.id, "ghp_" + String(repeating: "a", count: 36))
        try store.setFolder(item.id, "AKIAIOSFODNN7EXAMPLE")
        let saved = try #require(try store.pinned().first { $0.id == item.id })
        #expect(saved.title == nil)
        #expect(saved.folder == nil)
        try store.setFolder(item.id, "仕事")
        #expect(try store.renameFolder("仕事", to: "AKIAIOSFODNN7EXAMPLE") == nil)
        #expect(try store.folders() == ["仕事"])
    }
}
