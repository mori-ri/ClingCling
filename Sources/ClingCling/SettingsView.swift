import AppKit
import ApplicationServices
import ClingClingCore
import SwiftUI

enum SettingsPageID: String, CaseIterable, Identifiable {
    case general
    case ai
    case privacy
    case applications

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "一般"
        case .ai: "AI"
        case .privacy: "プライバシー"
        case .applications: "アプリ別"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "起動、言語、貼り付け、履歴の保存"
        case .ai: "AI に渡す Action と送り先"
        case .privacy: "保存しないものと、Mac の外に出すもの"
        case .applications: "アプリごとの取り込みルール"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .ai: "sparkles"
        case .privacy: "lock.shield"
        case .applications: "app.badge"
        }
    }
}

/// 設定画面のローカル状態。
/// Command Line Tools には SwiftUI の `@State` マクロ用プラグインが含まれないため、ObservableObject で持つ。
@MainActor
final class SettingsFormState: ObservableObject {
    @Published var page = SettingsPageID.general
    @Published var stats = (rate: 0.0, total: 0)
    @Published var selectedApp = ""
    @Published var hasAccessibility = AXIsProcessTrusted()

    init() {
        #if DEBUG
        // 開発用: CLINGCLING_SETTINGS_PAGE=ai などで最初に開くページを指定する
        if let raw = ProcessInfo.processInfo.environment["CLINGCLING_SETTINGS_PAGE"],
           let page = SettingsPageID(rawValue: raw) {
            self.page = page
        }
        #endif
    }
}

/// `@State` を使わずにホバーを持つための入れ物（理由は `SettingsFormState` を参照）
@MainActor
private final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// サイドバーと、選択中のページからなる設定ウインドウ
struct SettingsView: View {
    static let defaultSize = NSSize(width: 860, height: 600)

    @ObservedObject var settings: AppSettings
    let model: AppModel

    @StateObject private var form = SettingsFormState()

    var body: some View {
        HStack(spacing: 0) {
            // 信号機ボタンはこのパネルの上端の内側に置く
            Sidebar(form: form)
                .frame(width: 212)
                .glassPanel(cornerRadius: 18)
                .padding(8)
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(page: form.page)
                page(form.page)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(form.page)
        }
        .background(GlassBackdrop())
        .background(WindowButtonsInset(dx: 8, dy: 6))
        .ignoresSafeArea()
        .tint(Theme.tint)
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder
    private func page(_ page: SettingsPageID) -> some View {
        switch page {
        case .general: GeneralPage(settings: settings, model: model, form: form)
        case .ai: AIPage(settings: settings)
        case .privacy: PrivacyPage(settings: settings)
        case .applications: ApplicationsPage(settings: settings, form: form)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var form: SettingsFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppLogo(height: 26)
                Text("ClingCling")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
            }
            .padding(.horizontal, 16)
            // タイトルバーを隠しているので、信号機ボタンの分だけ下げる
            .padding(.top, 44)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPageID.allCases) { page in
                    SidebarItem(page: page, isSelected: form.page == page) { form.page = page }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 2) {
                SidebarLink(title: "スポンサーになる", symbol: "heart", url: ProjectLinks.sponsors)
                SidebarLink(title: "フィードバック・要望", symbol: "bubble.left", url: ProjectLinks.newFeedback)
                SidebarLink(title: "GitHub リポジトリ", symbol: "chevron.left.forwardslash.chevron.right",
                            url: ProjectLinks.repository)
                if let license = ProjectLinks.license {
                    SidebarLink(title: "ライセンス", symbol: "doc.text", url: license)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("バージョン \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarItem: View {
    let page: SettingsPageID
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                if isSelected {
                    shape.fill(Theme.selection)
                        .overlay(shape.strokeBorder(Theme.rim, lineWidth: 0.5))
                        .shadow(color: Theme.selectionShadow, radius: 3, y: 1)
                } else if hover.isHovered {
                    shape.fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// ブラウザなどでページを開く。設定のページと見分けられるよう `SidebarItem` より控えめにする。
private struct SidebarLink: View {
    let title: LocalizedStringKey
    let symbol: String
    let url: URL
    @StateObject private var hover = HoverState()

    var body: some View {
        Button {
            ProjectLinks.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(hover.isHovered ? 1 : 0)
            }
            .foregroundStyle(hover.isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                if hover.isHovered { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .help(url.isFileURL ? "" : url.absoluteString)
    }
}

private struct PageHeader: View {
    let page: SettingsPageID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
            Text(page.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 8)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    let model: AppModel
    @ObservedObject var form: SettingsFormState

    var body: some View {
        SettingsPage {
            SettingsSection {
                ToggleRow("ログイン時に起動", isOn: Binding(get: { settings.launchAtLogin },
                                                    set: { settings.launchAtLogin = $0 }))
                if let note = settings.launchAtLoginNote { NoteRow(note, color: .red) }
                PickerRow("表示言語", selection: $settings.appLanguage) {
                    Text("システム既定").tag(AppLanguage.system)
                    // どちらの表示言語からも探せるよう、言語の名前はその言語で書く
                    Text(verbatim: "日本語").tag(AppLanguage.japanese) // no-l10n
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                if settings.appLanguage != settings.appLanguageAtLaunch {
                    LabeledRow("再起動すると表示言語が切り替わります。") {
                        Button("今すぐ再起動") { AppRelauncher.relaunch() }
                    }
                }
                ShortcutRow(settings: settings, model: model)
                ToggleRow("Copy 後に直前のアプリへ貼り付ける", isOn: $settings.pasteAfterCopy)
                    .onChange(of: settings.pasteAfterCopy) { _, on in
                        if on { ActionExecutor.requestAccessibility() }
                    }
            }
            SettingsSection(title: "権限") {
                PermissionRow(title: "アクセシビリティ", granted: form.hasAccessibility) {
                    ActionExecutor.openAccessibilitySettings()
                }
                NoteRow("自動での貼り付け、カーソル位置の取得、AI アプリへの受け渡しに使います。")
            }
            SettingsSection(title: "履歴", footer: "Pin した Item は期間・件数の上限に関係なく残ります。履歴は Time Machine のバックアップに含めません。") {
                PickerRow("保存件数", selection: $settings.historyLimit) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0) 件").tag($0) }
                }
                PickerRow("保存期間", selection: $settings.retentionDays) {
                    Text("1 日").tag(1)
                    Text("7 日").tag(7)
                    Text("30 日").tag(30)
                    Text("90 日").tag(90)
                    Text("無期限").tag(0)
                }
            }
            SettingsSection(title: "Smart Actions の学習") {
                LabeledRow("First Action Selection Rate") {
                    Group {
                        if form.stats.total == 0 {
                            Text(verbatim: "—")
                        } else {
                            Text("\(Int((form.stats.rate * 100).rounded()))%（\(form.stats.total) 回中）")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                LabeledRow("学習データ") {
                    Button("リセット") {
                        try? model.store.resetLearning()
                        form.stats = model.store.firstActionSelectionRate()
                    }
                }
            }
        }
        .onAppear {
            form.stats = model.store.firstActionSelectionRate()
            form.hasAccessibility = AXIsProcessTrusted()
        }
        // システム設定で許可して戻ってきたときに反映する
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            form.hasAccessibility = AXIsProcessTrusted()
            settings.refreshLaunchAtLogin()
        }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let granted: Bool
    let open: () -> Void

    var body: some View {
        SettingsRow {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(title)
                Spacer(minLength: 12)
                if granted {
                    Text("許可済み").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("許可する…", action: open)
                }
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsSection(footer: "「保存しない」Item はディスクに書かず、メモリ上で 5 分間だけ保持します。") {
                ToggleRow("パスワード・API キーを保存しない", isOn: $settings.neverSavePasswords)
                ToggleRow("認証コードを保存しない", isOn: $settings.neverSaveVerificationCodes)
                ToggleRow("Password Manager からのコピーを無視", isOn: $settings.excludePasswordManagers)
            }
            SettingsSection(title: "AI への受け渡し",
                            footer: "本文が Mac の外に出るのは、Local Privacy Gate を通過した Item に対してあなたが Action を選んだときだけです。Secret・個人情報・判定不能な Item は渡しません。送り先は AI のページで設定します。") {
                ToggleRow("説明・整える・短くする・翻訳を AI に渡す", isOn: $settings.externalAIEnabled)
            }
        }
    }
}

// MARK: - AI

private struct AIPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsSection(footer: "API は使いません。AI のアプリに指示と本文を貼り付けるか、URL に入れて Web 版を開きます。確認画面では ⇥ で送り先を切り替えられます。") {
                ToggleRow("AI に渡す Action を使う", isOn: $settings.externalAIEnabled)
                Group {
                    ToggleRow("渡す前に毎回確認する", isOn: $settings.confirmAISend)
                    PickerRow("既定の送り先", selection: $settings.defaultDestinationID) {
                        ForEach(settings.aiDestinations) { Text($0.name).tag($0.id) }
                    }
                }
                .disabled(!settings.externalAIEnabled)
            }

            SettingsSection(title: "送り先",
                            footer: "アプリへの貼り付けにはアクセシビリティ権限が必要です。URL では {prompt}（指示 + 本文）/ {instruction} / {text} が URL エンコードされて入ります。") {
                ForEach($settings.aiDestinations) { $destination in
                    DestinationEditor(destination: $destination) {
                        settings.aiDestinations.removeAll { $0.id == destination.id }
                    }
                }
                SettingsRow {
                    HStack {
                        Button("アプリを追加") {
                            settings.aiDestinations.append(AIDestination(name: String(localized: "新しいアプリ"), kind: .app))
                        }
                        Button("URL を追加") {
                            settings.aiDestinations.append(AIDestination(
                                name: String(localized: "新しい URL"), kind: .url, urlTemplate: "https://example.com/?q={prompt}"))
                        }
                        Spacer()
                        Button("既定に戻す") { settings.aiDestinations = AIDestination.builtIns }
                    }
                }
            }

            SettingsSection(title: "自作の Action",
                            footer: "アクションメニューの末尾に上から ⌘4–9 で並びます。外部に渡せる Item（Local only 以外）にだけ表示されます。") {
                ForEach($settings.customAIActions) { $custom in
                    CustomActionEditor(custom: $custom, destinations: settings.aiDestinations) {
                        settings.customAIActions.removeAll { $0.id == custom.id }
                    }
                }
                SettingsRow {
                    Button("Action を追加") {
                        settings.customAIActions.append(CustomAIAction(name: String(localized: "新しい Action"), instruction: ""))
                    }
                }
            }

            SettingsSection(title: "指示文", footer: "空欄のときは薄く表示されている既定の指示文を使います。") {
                ForEach(AIPrompt.allCases) { prompt in
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(prompt.title)
                            TextField(prompt.title, text: Binding(
                                get: { settings.aiInstructions[prompt.rawValue] ?? "" },
                                set: { settings.aiInstructions[prompt.rawValue] = $0 }
                            ), prompt: Text(prompt.defaultInstruction), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                            .labelsHidden()
                        }
                    }
                }
            }
        }
    }
}

private struct CustomActionEditor: View {
    @Binding var custom: CustomAIAction
    let destinations: [AIDestination]
    let onDelete: () -> Void

    var body: some View {
        SettingsRow {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    EditorField("名前") {
                        TextField("名前", text: $custom.name)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    EditorField("指示文") {
                        TextField("指示文", text: $custom.instruction,
                                  prompt: Text("例: 次の文章を箇条書きで 3 行に要約してください。"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...6)
                            .labelsHidden()
                    }
                    EditorField("送り先") {
                        Picker("送り先", selection: $custom.destinationID) {
                            Text("既定の送り先").tag(UUID?.none)
                            ForEach(destinations) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button("この Action を削除", role: .destructive, action: onDelete)
                }
                .padding(.top, 8)
            } label: {
                Label(custom.name.isEmpty ? String(localized: "（名前なし）") : custom.name, systemImage: CustomAIAction.systemImage)
            }
        }
    }
}

private struct DestinationEditor: View {
    @Binding var destination: AIDestination
    let onDelete: () -> Void

    private var installedName: String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: destination.bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
    }

    var body: some View {
        SettingsRow {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    EditorField("名前") {
                        TextField("名前", text: $destination.name)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    EditorField("種類") {
                        Picker("種類", selection: $destination.kind) {
                            Text("アプリに貼り付け").tag(AIDestination.Kind.app)
                            Text("URL を開く").tag(AIDestination.Kind.url)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    switch destination.kind {
                    case .app:
                        EditorField("アプリ") {
                            HStack {
                                Text(installedName ?? (destination.bundleID.isEmpty ? String(localized: "未選択") : String(localized: "見つかりません")))
                                    .foregroundStyle(installedName == nil ? .red : .secondary)
                                Button("選択…", action: chooseApp)
                            }
                        }
                        Toggle("⌘N で新しいチャットを開いてから貼り付ける", isOn: $destination.newChat)
                        Toggle("貼り付け後に ↩ で送信する", isOn: $destination.autoSend)
                    case .url:
                        EditorField("URL テンプレート") {
                            TextField("URL テンプレート", text: $destination.urlTemplate)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                        }
                    }
                    Button("この送り先を削除", role: .destructive, action: onDelete)
                }
                .padding(.top, 8)
            } label: {
                Label(destination.name, systemImage: destination.systemImage)
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        destination.bundleID = bundleID
        if destination.name == String(localized: "新しいアプリ") {
            destination.name = FileManager.default.displayName(atPath: url.path)
        }
    }
}

// MARK: - Applications

private struct ApplicationsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var form: SettingsFormState

    private var runningApps: [NSRunningApplication] {
        let known = Set(settings.appPolicies.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !known.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        SettingsPage {
            SettingsSection(footer: "Password Manager はプライバシーの設定で常に除外されます。行を右クリックで削除できます。") {
                ForEach($settings.appPolicies) { $entry in
                    PickerRow(entry.name, selection: $entry.policy) {
                        Text("Capture").tag(AppCapturePolicy.capture)
                        Text("Never Capture").tag(AppCapturePolicy.neverCapture)
                        Text("Local Only").tag(AppCapturePolicy.localOnly)
                    }
                    .contextMenu {
                        Button("削除") { settings.appPolicies.removeAll { $0.id == entry.id } }
                    }
                }
                if settings.appPolicies.isEmpty {
                    SettingsRow {
                        Text("アプリ単位のルールはまだありません。").foregroundStyle(.secondary)
                    }
                }
            }
            SettingsSection(title: "アプリを追加（起動中のアプリから選択）") {
                LabeledRow("アプリ") {
                    HStack {
                        Picker("アプリ", selection: $form.selectedApp) {
                            Text("選択…").tag("")
                            ForEach(runningApps, id: \.bundleIdentifier) { app in
                                Text(app.localizedName ?? app.bundleIdentifier!).tag(app.bundleIdentifier!)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("追加") {
                            let name = NSWorkspace.shared.runningApplications
                                .first { $0.bundleIdentifier == form.selectedApp }?.localizedName ?? form.selectedApp
                            settings.appPolicies.append(AppPolicyEntry(bundleID: form.selectedApp, name: name, policy: .localOnly))
                            form.selectedApp = ""
                        }
                        .disabled(form.selectedApp.isEmpty)
                    }
                }
            }
        }
    }
}
