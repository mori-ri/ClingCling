import ClingClingCore
import SwiftUI

/// お知らせのページのローカル状態（`@State` を使わない理由は `SettingsFormState` を参照）
@MainActor
private final class NewsPageState: ObservableObject {
    /// ページがノートを頼んだら立てる。最初の答えが来る前に「お知らせはありません」と出さないため
    @Published var requested = false
}

/// 新しいバージョンが出ていればダウンロードのボタン、続けて GitHub のリリースノートを新しい順に出す
struct NewsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateChecker
    @StateObject private var state = NewsPageState()

    var body: some View {
        SettingsPage {
            if let version = updates.availableVersion {
                SettingsSection {
                    LabeledRow("新しいバージョン \(version) があります") {
                        Button("ダウンロード") { ProjectLinks.open(ProjectLinks.latestRelease) }
                            .buttonStyle(.borderedProminent)
                    }
                    NoteRow("リリースのページから dmg をダウンロードして開き、ClingCling を終了してから、ClingCling.app を「アプリケーション」フォルダにドラッグして置き換えます。設定と履歴は引き継がれます。")
                }
            }
            if updates.notes.isEmpty {
                SettingsSection { status }
            }
            ForEach(updates.notes) { note in
                ReleaseNoteSection(note: note, current: updates.currentVersion)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("GitHub のリリースノートを表示しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("すべてのリリースを GitHub で見る") { ProjectLinks.open(ProjectLinks.releases) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 4)
        }
        .task {
            // 設定は GitHub に問い合わせるかどうか。オフのときはボタンを押すまで待つ
            guard updates.notes.isEmpty, settings.checksForUpdates else { return }
            state.requested = true
            // 起動時の確認がまだ動いているかもしれない。その答えでページが埋まる
            if !updates.isLoading { await updates.loadNotes() }
        }
        // ページに出たものは読んだことにする。開いている間に届いたノートも同じ
        .task(id: updates.notes.first?.id) {
            if updates.hasUnreadNotes(lastSeen: settings.lastSeenReleaseNotes) {
                settings.lastSeenReleaseNotes = updates.notes.first?.version.text
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if updates.isLoading || (!state.requested && settings.checksForUpdates) {
            SettingsRow {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").foregroundStyle(.secondary)
                }
            }
        } else if updates.loadFailed {
            LabeledRow("お知らせを読み込めませんでした。インターネットへの接続を確認してください。") {
                Button("再試行") { Task { await load() } }
            }
        } else if !state.requested {
            LabeledRow("新しいバージョンの確認がオフのため、お知らせを読み込んでいません。") {
                Button("読み込む") { Task { await load() } }
            }
        } else {
            NoteRow("お知らせはまだありません。")
        }
    }

    private func load() async {
        state.requested = true
        await updates.loadNotes()
    }
}

/// 1 つのリリース: バージョンと日付の下に、ノートのカード
private struct ReleaseNoteSection: View {
    let note: ReleaseNote
    let current: AppVersion?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("バージョン \(note.version.text)")
                    .font(.system(size: 13, weight: .semibold))
                if let current, note.version == current {
                    VersionBadge(title: "使用中", isProminent: false)
                } else if let current, note.version > current {
                    VersionBadge(title: "新しいバージョン", isProminent: true)
                }
                Spacer()
                if let date = note.publishedAt {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            SettingsSection {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        if note.blocks.isEmpty {
                            Text("このバージョンの説明はありません。").foregroundStyle(.secondary)
                        }
                        ForEach(Array(note.blocks.enumerated()), id: \.offset) { index, block in
                            ReleaseNoteBlockView(block: block, isFirst: index == 0)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ReleaseNoteBlockView: View {
    let block: ReleaseNoteBlock
    let isFirst: Bool

    var body: some View {
        switch block {
        case .heading(let text):
            Text(ReleaseNotes.inline(text))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, isFirst ? 0 : 8)
        case .paragraph(let text):
            Text(ReleaseNotes.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).foregroundStyle(.secondary)
                Text(ReleaseNotes.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 16)
        }
    }
}

/// バージョンの横の「使用中」「新しいバージョン」
private struct VersionBadge: View {
    let title: LocalizedStringKey
    let isProminent: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            // 白い文字は `Theme.accent` の上に載せる（白文字とのコントラストを取ってある）
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(isProminent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.selection), in: Capsule())
            .overlay(Capsule().strokeBorder(isProminent ? Color.clear : Theme.cardStroke, lineWidth: 1))
    }
}
