import AppKit
import ClingClingCore
import SwiftUI

/// 設定画面のローカル状態。
/// Command Line Tools には SwiftUI の `@State` マクロ用プラグインが含まれないため、ObservableObject で持つ。
@MainActor
final class SettingsFormState: ObservableObject {
    @Published var stats = (rate: 0.0, total: 0)
    @Published var selectedApp = ""
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let model: AppModel

    @StateObject private var form = SettingsFormState()

    var body: some View {
        TabView {
            GeneralTab(settings: settings, model: model, form: form).tabItem { Label("General", systemImage: "gearshape") }
            AITab(settings: settings).tabItem { Label("AI", systemImage: "sparkles") }
            PrivacyTab(settings: settings, form: form).tabItem { Label("Privacy", systemImage: "lock.shield") }
            ApplicationsTab(settings: settings, form: form).tabItem { Label("Applications", systemImage: "app.badge") }
        }
        .frame(width: 520, height: 440)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    let model: AppModel
    @ObservedObject var form: SettingsFormState

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: Binding(get: { settings.launchAtLogin },
                                                  set: { settings.launchAtLogin = $0 }))
                LabeledContent("ショートカット", value: "⌘⇧V")
                Toggle("Copy 後に直前のアプリへ貼り付ける", isOn: $settings.pasteAfterCopy)
                    .onChange(of: settings.pasteAfterCopy) { _, on in
                        if on { ActionExecutor.requestAccessibility() }
                    }
                Text("貼り付けにはアクセシビリティ権限が必要です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("履歴") {
                Picker("保存件数", selection: $settings.historyLimit) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0) 件").tag($0) }
                }
                Picker("保存期間", selection: $settings.retentionDays) {
                    Text("1 日").tag(1)
                    Text("7 日").tag(7)
                    Text("30 日").tag(30)
                    Text("90 日").tag(90)
                    Text("無期限").tag(0)
                }
                Text("Pin した Item は期間・件数の上限に関係なく残ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Smart Actions の学習") {
                LabeledContent("First Action Selection Rate",
                               value: form.stats.total == 0 ? "—" : String(format: "%.0f%%（%d 回中）", form.stats.rate * 100, form.stats.total))
                Button("学習データをリセット") {
                    try? model.store.resetLearning()
                    form.stats = model.store.firstActionSelectionRate()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { form.stats = model.store.firstActionSelectionRate() }
    }
}

private struct PrivacyTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var form: SettingsFormState

    var body: some View {
        Form {
            Section {
                Toggle("パスワード・API キーを保存しない", isOn: $settings.neverSavePasswords)
                Toggle("認証コードを保存しない", isOn: $settings.neverSaveVerificationCodes)
                Toggle("Password Manager からのコピーを無視", isOn: $settings.excludePasswordManagers)
                Text("「保存しない」Item はディスクに書かず、メモリ上で 5 分間だけ保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI への受け渡し") {
                Toggle("説明・整える・短くする・翻訳を AI に渡す", isOn: $settings.externalAIEnabled)
                Text("本文が Mac の外に出るのは、Local Privacy Gate を通過した Item に対してあなたが Action を選んだときだけです。Secret・個人情報・判定不能な Item は渡しません。送り先は AI タブで設定します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AITab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("AI に渡す Action を使う", isOn: $settings.externalAIEnabled)
                Group {
                    Toggle("渡す前に毎回確認する", isOn: $settings.confirmAISend)
                    Picker("既定の送り先", selection: $settings.defaultDestinationID) {
                        ForEach(settings.aiDestinations) { Text($0.name).tag($0.id) }
                    }
                }
                .disabled(!settings.externalAIEnabled)
            } footer: {
                Text("API は使いません。AI のアプリに指示と本文を貼り付けるか、URL に入れて Web 版を開きます。確認画面では ⇥ で送り先を切り替えられます。")
            }

            Section {
                ForEach($settings.aiDestinations) { $destination in
                    DestinationEditor(destination: $destination) {
                        settings.aiDestinations.removeAll { $0.id == destination.id }
                    }
                }
                HStack {
                    Button("アプリを追加") {
                        settings.aiDestinations.append(AIDestination(name: "新しいアプリ", kind: .app))
                    }
                    Button("URL を追加") {
                        settings.aiDestinations.append(AIDestination(
                            name: "新しい URL", kind: .url, urlTemplate: "https://example.com/?q={prompt}"))
                    }
                    Spacer()
                    Button("既定に戻す") { settings.aiDestinations = AIDestination.builtIns }
                }
            } header: {
                Text("送り先")
            } footer: {
                Text("アプリへの貼り付けにはアクセシビリティ権限が必要です。URL では {prompt}（指示 + 本文）/ {instruction} / {text} が URL エンコードされて入ります。")
            }

            Section {
                ForEach($settings.customAIActions) { $custom in
                    CustomActionEditor(custom: $custom, destinations: settings.aiDestinations) {
                        settings.customAIActions.removeAll { $0.id == custom.id }
                    }
                }
                Button("Action を追加") {
                    settings.customAIActions.append(CustomAIAction(name: "新しい Action", instruction: ""))
                }
            } header: {
                Text("自作の Action")
            } footer: {
                Text("アクションメニューの末尾に上から ⌘4–9 で並びます。外部に渡せる Item（Local only 以外）にだけ表示されます。")
            }

            Section {
                ForEach(AIPrompt.allCases) { prompt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.title).font(.callout)
                        TextField(prompt.defaultInstruction, text: Binding(
                            get: { settings.aiInstructions[prompt.rawValue] ?? "" },
                            set: { settings.aiInstructions[prompt.rawValue] = $0 }
                        ), axis: .vertical)
                        .lineLimit(2...5)
                        .labelsHidden()
                    }
                }
            } header: {
                Text("指示文")
            } footer: {
                Text("空欄のときは薄く表示されている既定の指示文を使います。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CustomActionEditor: View {
    @Binding var custom: CustomAIAction
    let destinations: [AIDestination]
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            TextField("名前", text: $custom.name)
            VStack(alignment: .leading, spacing: 4) {
                Text("指示文").font(.callout)
                TextField("例: 次の文章を箇条書きで 3 行に要約してください。", text: $custom.instruction, axis: .vertical)
                    .lineLimit(2...6)
                    .labelsHidden()
            }
            Picker("送り先", selection: $custom.destinationID) {
                Text("既定の送り先").tag(UUID?.none)
                ForEach(destinations) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Button("この Action を削除", role: .destructive, action: onDelete)
        } label: {
            Label(custom.name.isEmpty ? "（名前なし）" : custom.name, systemImage: CustomAIAction.systemImage)
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
        DisclosureGroup {
            TextField("名前", text: $destination.name)
            Picker("種類", selection: $destination.kind) {
                Text("アプリに貼り付け").tag(AIDestination.Kind.app)
                Text("URL を開く").tag(AIDestination.Kind.url)
            }
            switch destination.kind {
            case .app:
                LabeledContent("アプリ") {
                    HStack {
                        Text(installedName ?? (destination.bundleID.isEmpty ? "未選択" : "見つかりません"))
                            .foregroundStyle(installedName == nil ? .red : .secondary)
                        Button("選択…", action: chooseApp)
                    }
                }
                Toggle("⌘N で新しいチャットを開いてから貼り付ける", isOn: $destination.newChat)
                Toggle("貼り付け後に ↩ で送信する", isOn: $destination.autoSend)
            case .url:
                TextField("URL テンプレート", text: $destination.urlTemplate)
                    .font(.system(.body, design: .monospaced))
            }
            Button("この送り先を削除", role: .destructive, action: onDelete)
        } label: {
            Label(destination.name, systemImage: destination.systemImage)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        destination.bundleID = bundleID
        if destination.name == "新しいアプリ" {
            destination.name = FileManager.default.displayName(atPath: url.path)
        }
    }
}

private struct ApplicationsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var form: SettingsFormState

    private var runningApps: [NSRunningApplication] {
        let known = Set(settings.appPolicies.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !known.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                ForEach($settings.appPolicies) { $entry in
                    Picker(entry.name, selection: $entry.policy) {
                        Text("Capture").tag(AppCapturePolicy.capture)
                        Text("Never Capture").tag(AppCapturePolicy.neverCapture)
                        Text("Local Only").tag(AppCapturePolicy.localOnly)
                    }
                    .contextMenu {
                        Button("削除") { settings.appPolicies.removeAll { $0.id == entry.id } }
                    }
                }
                if settings.appPolicies.isEmpty {
                    Text("アプリ単位のルールはまだありません。").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Password Manager は Privacy の設定で常に除外されます。行を右クリックで削除できます。")
            }
            Section("アプリを追加（起動中のアプリから選択）") {
                HStack {
                    Picker("アプリ", selection: $form.selectedApp) {
                        Text("選択…").tag("")
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Text(app.localizedName ?? app.bundleIdentifier!).tag(app.bundleIdentifier!)
                        }
                    }
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
        .formStyle(.grouped)
    }
}
