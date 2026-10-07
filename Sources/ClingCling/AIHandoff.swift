import AppKit
import ApplicationServices
import ClingClingCore

/// AI の渡し先。API は直接呼ばず、AI のアプリか Web に「指示 + 本文」を渡してそちらで処理してもらう。
struct AIDestination: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// アプリを前面に出し、新規チャットにプロンプトを貼り付ける
        case app
        /// URL テンプレートにプロンプトを埋め込んで開く
        case url
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// `.app` の対象
    var bundleID = ""
    /// `.app`: 貼り付け前に ⌘N で新しいチャットを開く
    var newChat = true
    /// `.app`: 貼り付け後に ↩ で送信する
    var autoSend = false
    /// `.url`: `{prompt}`（指示 + 本文）/ `{instruction}` / `{text}` を URL エンコードして埋め込む
    var urlTemplate = ""

    static let claudeApp = AIDestination(
        id: UUID(uuidString: "6A0C3E2B-1F0E-4C55-9C0E-0000000000C1")!,
        name: "Claude アプリ", kind: .app, bundleID: "com.anthropic.claudefordesktop")
    static let chatGPTApp = AIDestination(
        id: UUID(uuidString: "6A0C3E2B-1F0E-4C55-9C0E-0000000000C2")!,
        name: "ChatGPT アプリ", kind: .app, bundleID: "com.openai.chat")
    static let claudeWeb = AIDestination(
        id: UUID(uuidString: "6A0C3E2B-1F0E-4C55-9C0E-0000000000C3")!,
        name: "Claude（Web）", kind: .url, urlTemplate: "https://claude.ai/new?q={prompt}")
    static let chatGPTWeb = AIDestination(
        id: UUID(uuidString: "6A0C3E2B-1F0E-4C55-9C0E-0000000000C4")!,
        name: "ChatGPT（Web）", kind: .url, urlTemplate: "https://chatgpt.com/?q={prompt}")

    static let builtIns = [claudeApp, chatGPTApp, claudeWeb, chatGPTWeb]

    var systemImage: String { kind == .app ? "macwindow" : "globe" }
}

/// ユーザーが自作した AI Action。アクションメニューの末尾に並ぶ（⌘4–9）。
struct CustomAIAction: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var instruction: String
    /// nil なら既定の送り先
    var destinationID: UUID?

    static let systemImage = "wand.and.stars"
}

/// 確認画面に出して AI に渡す依頼
struct AIRequest {
    let item: ClipItem
    let title: String
    let systemImage: String
    let prompt: AIHandoff.Prompt
    /// 確認画面で最初に選ばれている送り先
    let destinationID: UUID?
    /// 学習に使う Smart Action と表示位置（自作 Action は学習しない）
    let learning: (action: SmartAction, position: Int)?
}

/// AI Action ごとの指示文。設定で編集できる。
enum AIPrompt: String, CaseIterable, Identifiable {
    case explain
    case explainError
    case polish
    case shorten
    case translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: "説明する"
        case .explainError: "説明する（エラー）"
        case .polish: "文章を整える"
        case .shorten: "短くする"
        case .translate: "翻訳する"
        }
    }

    var defaultInstruction: String {
        switch self {
        case .explain: "次の内容が何をしているのか、簡潔に説明してください。"
        case .explainError: "次のエラーの原因として考えられることと、具体的な解決手順を簡潔に説明してください。"
        case .polish: "次の文章の文法を直し、意味・トーン・言語を変えずに読みやすく整えてください。整えた文章だけを出力してください。"
        case .shorten: "次の文章を、要点・トーン・言語を保ったまま半分程度の長さに短くしてください。短くした文章だけを出力してください。"
        case .translate: "次のテキストを翻訳してください。日本語なら自然な英語に、それ以外なら自然な日本語にしてください。訳文だけを出力してください。"
        }
    }

    static func kind(for action: SmartAction, item: ClipItem) -> AIPrompt? {
        switch action {
        case .explain: item.contentType == .error ? .explainError : .explain
        case .polish: .polish
        case .shorten: .shorten
        case .translate: .translate
        default: nil
        }
    }
}

@MainActor
enum AIHandoff {
    /// これより長い URL はブラウザやサーバーに切り捨てられやすいので送らない
    static let maxURLLength = 8_000

    enum Failure: LocalizedError {
        case localOnly
        case appNotFound(String)
        case needsAccessibility
        case invalidTemplate
        case tooLong

        var errorDescription: String? {
            switch self {
            case .localOnly: "この Item は Local only のため AI に送れません。"
            case .appNotFound(let name): "\(name) が見つかりません。Settings → AI で送り先を確認してください。"
            case .needsAccessibility:
                "アプリへ貼り付けるにはアクセシビリティ権限が必要です（システム設定 → プライバシーとセキュリティ → アクセシビリティ）。"
            case .invalidTemplate: "送り先の URL テンプレートが正しくありません。"
            case .tooLong: "本文が長すぎて URL では送れません。アプリの送り先を使ってください。"
            }
        }
    }

    struct Prompt {
        let instruction: String
        let text: String
        var full: String { "\(instruction)\n\n---\n\(text)" }
    }

    static func request(for action: SmartAction, position: Int, item: ClipItem, settings: AppSettings) -> AIRequest? {
        guard let kind = AIPrompt.kind(for: action, item: item) else { return nil }
        return AIRequest(item: item, title: Presentation.title(for: action), systemImage: action.systemImage,
                         prompt: Prompt(instruction: settings.instruction(for: kind), text: item.content),
                         destinationID: nil, learning: (action, position))
    }

    static func request(for custom: CustomAIAction, item: ClipItem) -> AIRequest {
        AIRequest(item: item, title: custom.name, systemImage: CustomAIAction.systemImage,
                  prompt: Prompt(instruction: custom.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                                 text: item.content),
                  destinationID: custom.destinationID, learning: nil)
    }

    /// ポップアップを閉じた後に呼ぶ。アプリへの貼り付けは非同期に進む。
    static func send(_ request: AIRequest, to destination: AIDestination, model: AppModel) throws {
        // UI 側でも制御しているが、最後の砦としてここでも Fail Closed にする
        guard request.item.externalAllowed else { throw Failure.localOnly }
        let prompt = request.prompt
        switch destination.kind {
        case .url:
            NSWorkspace.shared.open(try url(for: prompt, template: destination.urlTemplate))
        case .app:
            try sendToApp(prompt.full, destination: destination, model: model)
        }
    }

    // MARK: - URL

    static func url(for prompt: Prompt, template: String) throws -> URL {
        // クエリ値として安全な文字だけを残す（& = + # などはエンコードする）
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/;:@$,!'()*")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let string = template
            .replacingOccurrences(of: "{prompt}", with: encode(prompt.full))
            .replacingOccurrences(of: "{instruction}", with: encode(prompt.instruction))
            .replacingOccurrences(of: "{text}", with: encode(prompt.text))
        guard string.count <= maxURLLength else { throw Failure.tooLong }
        guard let url = URL(string: string), url.scheme != nil else { throw Failure.invalidTemplate }
        return url
    }

    // MARK: - App

    private static func sendToApp(_ text: String, destination: AIDestination, model: AppModel) throws {
        guard ActionExecutor.requestAccessibility() else { throw Failure.needsAccessibility }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: destination.bundleID) else {
            throw Failure.appNotFound(destination.name)
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: destination.bundleID).isEmpty

        // プロンプトは一時的にクリップボードに載せ、貼り付け後に元の内容へ戻す
        let snapshot = model.snapshotPasteboard()
        model.writeToPasteboard(text, transient: true)
        let changeCount = NSPasteboard.general.changeCount

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }

        Task { @MainActor in
            defer {
                // 貼り付け後にユーザーが別のものをコピーしていたら戻さない
                if NSPasteboard.general.changeCount == changeCount { model.restorePasteboard(snapshot) }
            }
            guard await waitUntilFrontmost(destination.bundleID, timeout: wasRunning ? 3 : 15) else {
                NSLog("ClingCling: \(destination.name) did not become frontmost")
                NSSound.beep()
                return
            }
            // 起動直後は入力欄の準備ができていないことがある
            try? await Task.sleep(for: .milliseconds(wasRunning ? 300 : 2000))
            if destination.newChat {
                ActionExecutor.postKey(0x2D, flags: .maskCommand) // ⌘N
                try? await Task.sleep(for: .milliseconds(600))
            }
            ActionExecutor.postKey(0x09, flags: .maskCommand) // ⌘V
            if destination.autoSend {
                try? await Task.sleep(for: .milliseconds(300))
                ActionExecutor.postKey(0x24) // ↩
            }
            try? await Task.sleep(for: .milliseconds(1000))
        }
    }

    private static func waitUntilFrontmost(_ bundleID: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
