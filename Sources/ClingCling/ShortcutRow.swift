import AppKit
import ClingClingCore
import SwiftUI

/// キー入力を受けて、新しいショートカットを記録する
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// 設定できなかった理由
    @Published var note: String?

    private var monitor: Any?

    func start(model: AppModel) {
        guard !isRecording else { return }
        isRecording = true
        note = nil
        model.hotKey?.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // メニューバーから開いたポップアップへの入力は奪わない
            if event.window is PopupPanel { return event }
            self?.handle(event, model: model)
            return nil
        }
    }

    func stop(model: AppModel) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        note = nil
        model.hotKey?.resume()
    }

    private func handle(_ event: NSEvent, model: AppModel) {
        let shortcut = Shortcut(event: event)
        // 修飾キーなしの esc は取り消し
        if event.keyCode == 53, shortcut.modifiers.isEmpty { return stop(model: model) }
        if let problem = shortcut.problem {
            note = Self.message(for: problem)
            return
        }
        stop(model: model)
        apply(shortcut, model: model)
    }

    func apply(_ shortcut: Shortcut, model: AppModel) {
        note = model.applyShortcut(shortcut) ? nil : Self.failureMessage(for: shortcut)
    }

    /// 起動時に登録できなかったショートカットを知らせる
    func reportUnregistered(model: AppModel) {
        guard !isRecording, model.hotKey?.isRegistered == false else { return }
        note = Self.failureMessage(for: model.settings.shortcut)
    }

    private static func failureMessage(for shortcut: Shortcut) -> String {
        String(localized: "\(shortcut.displayName) を登録できませんでした。別の組み合わせを選んでください。")
    }

    private static func message(for problem: Shortcut.Problem) -> String {
        switch problem {
        case .needsModifier: String(localized: "⌘、⌃、⌥ のどれかを含めてください。")
        case .conflictsWithApps: String(localized: "⌘ か ⌥ だけの組み合わせはアプリの操作や文字の入力と重なるので、⌃ か ⇧ を加えてください。")
        case .unsupportedKey: String(localized: "このキーは使えません。")
        }
    }
}

/// ショートカットの選択と記録
struct ShortcutRow: View {
    @ObservedObject var settings: AppSettings
    let model: AppModel
    @StateObject private var recorder = ShortcutRecorder()

    private var options: [Shortcut] {
        Shortcut.presets.contains(settings.shortcut) ? Shortcut.presets : Shortcut.presets + [settings.shortcut]
    }

    var body: some View {
        // Group だと下の修飾子が子ごとに付き、補足の行が消えただけで onDisappear が走って記録が止まる
        VStack(alignment: .leading, spacing: 0) {
            LabeledRow("ショートカット") {
                HStack(spacing: 8) {
                    Picker("ショートカット", selection: Binding(get: { settings.shortcut },
                                                         set: { recorder.apply($0, model: model) })) {
                        ForEach(options, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(recorder.isRecording)
                    if recorder.isRecording {
                        Text("キーを押してください（esc で取り消し）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("取り消す") { recorder.stop(model: model) }
                    } else {
                        Button("記録…") { recorder.start(model: model) }
                    }
                }
            }
            if let note = recorder.note { NoteRow(note, color: .red) }
        }
        .onAppear { recorder.reportUnregistered(model: model) }
        // 記録中に別のページやアプリへ移ったら、元のショートカットに戻す
        .onDisappear { recorder.stop(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            recorder.stop(model: model)
        }
    }
}
