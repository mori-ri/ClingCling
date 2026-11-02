import ClingClingCore
import Foundation
import ServiceManagement

struct AppPolicyEntry: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var policy: AppCapturePolicy
    var id: String { bundleID }
}

enum AppLanguage: String {
    /// macOS の言語に合わせる
    case system
    case japanese
    case english

    /// `AppleLanguages` に書く値。nil なら macOS の設定に従う。
    var code: String? {
        switch self {
        case .system: nil
        case .japanese: "ja"
        case .english: "en"
        }
    }
}

/// UserDefaults に保存するユーザー設定
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // General
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published var pasteAfterCopy: Bool { didSet { defaults.set(pasteAfterCopy, forKey: "pasteAfterCopy") } }
    @Published var isPaused: Bool { didSet { defaults.set(isPaused, forKey: "isPaused") } }
    @Published var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }
    /// 表示言語。アプリのドメインの `AppleLanguages` に書くので、次の起動から反映される。
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            if let code = appLanguage.code {
                defaults.set([code], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    /// 起動したときの `appLanguage`。画面に出ている言語はこちら。
    let appLanguageAtLaunch: AppLanguage

    // Privacy
    @Published var neverSavePasswords: Bool { didSet { defaults.set(neverSavePasswords, forKey: "neverSavePasswords") } }
    @Published var neverSaveVerificationCodes: Bool {
        didSet { defaults.set(neverSaveVerificationCodes, forKey: "neverSaveVerificationCodes") }
    }
    @Published var excludePasswordManagers: Bool {
        didSet { defaults.set(excludePasswordManagers, forKey: "excludePasswordManagers") }
    }
    /// AI（Claude / ChatGPT のアプリや Web）へ本文を渡す Action を許可するか（既定 OFF）
    @Published var externalAIEnabled: Bool { didSet { defaults.set(externalAIEnabled, forKey: "externalAIEnabled") } }
    /// AI に渡す前に確認する
    @Published var confirmAISend: Bool { didSet { defaults.set(confirmAISend, forKey: "confirmCloudAI") } }

    // AI
    @Published var aiDestinations: [AIDestination] {
        didSet { defaults.set(try? JSONEncoder().encode(aiDestinations), forKey: "aiDestinations") }
    }
    @Published var defaultDestinationID: UUID {
        didSet { defaults.set(defaultDestinationID.uuidString, forKey: "defaultDestinationID") }
    }
    /// `AIPrompt.rawValue` → 指示文。未設定のものは既定の指示文を使う。
    @Published var aiInstructions: [String: String] {
        didSet { defaults.set(aiInstructions, forKey: "aiInstructions") }
    }
    @Published var customAIActions: [CustomAIAction] {
        didSet { defaults.set(try? JSONEncoder().encode(customAIActions), forKey: "customAIActions") }
    }

    // Applications
    @Published var appPolicies: [AppPolicyEntry] {
        didSet { defaults.set(try? JSONEncoder().encode(appPolicies), forKey: "appPolicies") }
    }

    init() {
        defaults.register(defaults: [
            "historyLimit": 500,
            "retentionDays": 30,
            "pasteAfterCopy": false,
            "isPaused": false,
            "neverSavePasswords": true,
            "neverSaveVerificationCodes": true,
            "excludePasswordManagers": true,
            "externalAIEnabled": false,
            "confirmCloudAI": true,
        ])
        historyLimit = defaults.integer(forKey: "historyLimit")
        retentionDays = defaults.integer(forKey: "retentionDays")
        pasteAfterCopy = defaults.bool(forKey: "pasteAfterCopy")
        isPaused = defaults.bool(forKey: "isPaused")
        shortcut = defaults.data(forKey: "shortcut")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        let language = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init) ?? .system
        appLanguage = language
        appLanguageAtLaunch = language
        neverSavePasswords = defaults.bool(forKey: "neverSavePasswords")
        neverSaveVerificationCodes = defaults.bool(forKey: "neverSaveVerificationCodes")
        excludePasswordManagers = defaults.bool(forKey: "excludePasswordManagers")
        externalAIEnabled = defaults.bool(forKey: "externalAIEnabled")
        confirmAISend = defaults.bool(forKey: "confirmCloudAI")
        let destinations = defaults.data(forKey: "aiDestinations")
            .flatMap { try? JSONDecoder().decode([AIDestination].self, from: $0) } ?? []
        aiDestinations = destinations.isEmpty ? AIDestination.builtIns : destinations
        defaultDestinationID = defaults.string(forKey: "defaultDestinationID").flatMap(UUID.init) ?? AIDestination.claudeApp.id
        aiInstructions = defaults.dictionary(forKey: "aiInstructions") as? [String: String] ?? [:]
        customAIActions = defaults.data(forKey: "customAIActions")
            .flatMap { try? JSONDecoder().decode([CustomAIAction].self, from: $0) } ?? []
        appPolicies = defaults.data(forKey: "appPolicies")
            .flatMap { try? JSONDecoder().decode([AppPolicyEntry].self, from: $0) } ?? []
    }

    var defaultDestination: AIDestination? {
        aiDestinations.first { $0.id == defaultDestinationID } ?? aiDestinations.first
    }

    func instruction(for prompt: AIPrompt) -> String {
        let custom = aiInstructions[prompt.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? prompt.defaultInstruction : custom
    }

    var privacySettings: PrivacySettings {
        PrivacySettings(
            neverSavePasswords: neverSavePasswords,
            neverSaveVerificationCodes: neverSaveVerificationCodes,
            excludePasswordManagers: excludePasswordManagers,
            appPolicies: Dictionary(appPolicies.map { ($0.bundleID, $0.policy) }, uniquingKeysWith: { _, last in last })
        )
    }

    // MARK: Launch at Login（.app バンドルとして起動している場合のみ有効）

    /// 「ログイン時に起動」を変更できなかったときの案内
    @Published private(set) var launchAtLoginNote: String?

    /// システム設定で許可されたら、案内を消して画面に反映する
    func refreshLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled { launchAtLoginNote = nil }
        objectWillChange.send()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginNote = SMAppService.mainApp.status == .requiresApproval
                    ? String(localized: "システム設定 › 一般 › ログイン項目 で ClingCling を許可してください。") : nil
            } catch {
                NSLog("ClingCling: launch at login failed: \(error)")
                launchAtLoginNote = String(localized: "設定できませんでした。ClingCling.app を「アプリケーション」フォルダに置いてから、もう一度お試しください。")
            }
            objectWillChange.send()
        }
    }
}
