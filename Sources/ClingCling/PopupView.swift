import ClingClingCore
import SwiftUI

/// カーソルの横に出るコンパクトな履歴メニュー。選択中の行から右にアクションメニューが開く。
struct PopupView: View {
    @ObservedObject var vm: PopupViewModel
    @FocusState private var searchFocused: Bool
    @StateObject private var layout = PopupLayout()

    /// ウインドウの外周。影を描く余白（PopupController の位置合わせもこの値を使う）
    static let margin: CGFloat = 18
    static let panelWidth: CGFloat = 320
    static let rowHeight: CGFloat = 28
    private static let sectionHeight: CGFloat = 26
    private static let maxListHeight: CGFloat = 12 * rowHeight

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            panel
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layout.panelHeight = $0 }
            if vm.actionsOpen, case .list = vm.mode, let row = vm.selectedRow {
                ActionMenu(vm: vm, entries: vm.menuEntries(for: row),
                           preview: vm.model.thumbnail(for: row.item, maxPixelSize: 480))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layout.menuHeight = $0 }
                    .padding(.top, menuOffset)
            }
        }
        .padding(Self.margin)
        .coordinateSpace(name: "popup")
        .fixedSize()
        .onAppear { searchFocused = true }
    }

    /// メニューの先頭項目を選択中の行に揃える。パネルの下にはみ出す分は上にずらす。
    private var menuOffset: CGFloat {
        let aligned = layout.selectedRowY - Self.margin - 6
        return max(0, min(aligned, layout.panelHeight - layout.menuHeight))
    }

    private var panel: some View {
        Group {
            switch vm.mode {
            case .list:
                VStack(spacing: 0) {
                    searchField
                    PanelDivider()
                    list
                    if let notice = vm.notice { noticeView(notice) }
                    if !vm.rows.isEmpty {
                        PanelDivider()
                        hints
                    }
                }
            case let .confirm(item, action, _):
                ConfirmView(vm: vm, item: item, title: Presentation.confirmationTitle(for: action), systemImage: action.systemImage,
                            action: action, request: nil)
            case .confirmAI(let request):
                ConfirmView(vm: vm, item: request.item, title: request.title, systemImage: request.systemImage,
                            action: nil, request: request)
            case let .result(title, text):
                ResultView(title: title, text: text, onPaste: vm.pasteResult, onBack: vm.back)
            }
        }
        .padding(6)
        .frame(width: Self.panelWidth)
        .popupSurface(cornerRadius: 12)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("入力して絞り込み", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !vm.query.isEmpty {
                Text("\(vm.rows.count) 件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if vm.rows.isEmpty {
            emptyView
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(vm.rows.enumerated()), id: \.element.id) { index, row in
                            if showsSections && index == 0 && vm.pinnedCount > 0 { sectionLabel("ピン留め") }
                            if showsSections && index == vm.pinnedCount && vm.pinnedCount > 0 { sectionLabel("履歴") }
                            ClipRow(row: row, query: vm.query, thumbnail: vm.model.thumbnail(for: row.item),
                                    selected: index == vm.selection,
                                    hovered: vm.hoveredID == row.id,
                                    onOpenActions: { vm.toggleActions(at: index) })
                                .id(row.id)
                                .background {
                                    if index == vm.selection {
                                        Color.clear.onGeometryChange(for: CGFloat.self) {
                                            $0.frame(in: .named("popup")).minY
                                        } action: { layout.selectedRowY = $0 }
                                    }
                                }
                                // 画像の拡大プレビューを行の横に出すための位置
                                .background {
                                    if vm.hoveredID == row.id {
                                        Color.clear.onGeometryChange(for: CGRect.self) {
                                            $0.frame(in: .named("popup"))
                                        } action: { vm.hoveredRowFrame = $0 }
                                    }
                                }
                                // 行のクリック = 直前のアプリへ貼り付け（› ボタンのクリックはボタン側が優先）
                                .onTapGesture {
                                    vm.selection = index
                                    vm.paste(row.item)
                                }
                                .onHover { inside in
                                    if inside { vm.hoveredID = row.id } else if vm.hoveredID == row.id { vm.hoveredID = nil }
                                }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight)
                .onChange(of: vm.selection) { _, newValue in
                    guard vm.rows.indices.contains(newValue) else { return }
                    proxy.scrollTo(vm.rows[newValue].id)
                }
            }
        }
    }

    private var showsSections: Bool { vm.query.isEmpty }

    /// 行数に合わせて縮む。多いときは 12 行分でスクロール。
    private var listHeight: CGFloat {
        let sections = showsSections && vm.pinnedCount > 0 && vm.rows.count > vm.pinnedCount ? 2
            : showsSections && vm.pinnedCount > 0 ? 1 : 0
        let total = CGFloat(vm.rows.count) * Self.rowHeight + CGFloat(sections) * Self.sectionHeight
        return min(total, Self.maxListHeight)
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: Self.sectionHeight, maxHeight: Self.sectionHeight, alignment: .bottomLeading)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: emptyIcon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(emptyTitle).font(.system(size: 13, weight: .semibold))
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }

    private var emptyIcon: String {
        if !vm.query.isEmpty { return "magnifyingglass" }
        return vm.model.settings.isPaused ? "pause.circle" : "doc.on.clipboard"
    }

    private var emptyTitle: LocalizedStringKey {
        if !vm.query.isEmpty { return "一致する履歴はありません" }
        return vm.model.settings.isPaused ? "キャプチャを一時停止中です" : "まだ履歴がありません"
    }

    private var emptyMessage: LocalizedStringKey {
        if !vm.query.isEmpty { return "esc で検索をクリアできます。" }
        if vm.model.settings.isPaused { return "メニューバーから再開できます。" }
        return "⌘C でコピーするとここに並びます。\n\(vm.model.settings.shortcut.displayName) でいつでもカーソルの横に開けます。"
    }

    private func noticeView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private var hints: some View {
        HStack(spacing: 12) {
            Text("↩ 貼り付け")
            Text("→ アクション")
            Text(vm.query.isEmpty ? "1–9 すぐ貼る" : "esc クリア")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
}

/// アクションメニューを選択中の行に揃えるための計測値
@MainActor
private final class PopupLayout: ObservableObject {
    /// 選択中の行の上端（"popup" 座標系）
    @Published var selectedRowY: CGFloat = 0
    @Published var panelHeight: CGFloat = 0
    @Published var menuHeight: CGFloat = 0
}

// MARK: - Row

struct ClipRow: View {
    let row: PopupViewModel.Row
    let query: String
    /// 画像 Item の縮小画像
    let thumbnail: NSImage?
    let selected: Bool
    let hovered: Bool
    let onOpenActions: () -> Void

    private var item: ClipItem { row.item }

    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .padding(.horizontal, -3)
            } else {
                Image(systemName: Presentation.rowIcon(for: item))
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }

            Text(Presentation.highlighted(Presentation.preview(item), query: query,
                                          masked: Presentation.isFullyMasked(item), selected: selected))
                .font(.system(size: 13, design: Presentation.isMonospaced(item.contentType) ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tag = Presentation.tag(item) {
                Text(tag)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }

            if selected {
                Button(action: onOpenActions) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .help("アクション（→）")
                .accessibilityLabel("アクション")
            } else if let number = row.number {
                Text("\(number)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: PopupView.rowHeight)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent : hovered ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .help(Presentation.meta(item))
    }
}

// MARK: - Action menu

struct ActionMenu: View {
    @ObservedObject var vm: PopupViewModel
    let entries: [PopupViewModel.MenuEntry]
    /// 画像 Item のプレビュー
    let preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.bottom, 2)
                PanelDivider()
            }
            ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                if index > 0 && entries[index - 1].group != entry.group { PanelDivider() }
                Button { vm.performMenuEntry(index) } label: {
                    label(for: entry, highlighted: index == vm.actionIndex)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { vm.actionIndex = index } }
            }
        }
        .padding(6)
        .frame(width: 248)
        .popupSurface(cornerRadius: 10)
    }

    private func label(for entry: PopupViewModel.MenuEntry, highlighted: Bool) -> some View {
        let secondary = highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary)
        return HStack(spacing: 8) {
            Image(systemName: icon(for: entry))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(secondary)
            Text(title(for: entry)).font(.system(size: 13))
            Spacer(minLength: 8)
            if entry.usesAI {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(secondary)
                    .help("指示を付けて本文を \(vm.model.settings.defaultDestination?.name ?? "AI") に渡します")
            }
            Text(shortcut(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Theme.accent : .clear)
        )
        .contentShape(Rectangle())
    }

    private func title(for entry: PopupViewModel.MenuEntry) -> String {
        switch entry {
        case .paste: String(localized: "貼り付け")
        case .smart(let action, _): Presentation.title(for: action)
        case .custom(let custom, _): custom.name
        case .pin(let isPinned): isPinned ? String(localized: "ピン留めを外す") : String(localized: "ピン留めする")
        case .delete: String(localized: "削除")
        }
    }

    private func icon(for entry: PopupViewModel.MenuEntry) -> String {
        switch entry {
        case .paste: "doc.on.clipboard"
        case .smart(let action, _): action.systemImage
        case .custom: CustomAIAction.systemImage
        case .pin(let isPinned): isPinned ? "pin.slash" : "pin"
        case .delete: "trash"
        }
    }

    private func shortcut(for entry: PopupViewModel.MenuEntry) -> String {
        switch entry {
        case .paste: "↩"
        case .smart(_, let n): "⌘\(n)"
        case .custom(_, let n): n.map { "⌘\($0)" } ?? ""
        case .pin: "⌘P"
        case .delete: "⌘⌫"
        }
    }
}

// MARK: - Confirm / Result

struct ConfirmView: View {
    @ObservedObject var vm: PopupViewModel
    let item: ClipItem
    let title: String
    let systemImage: String
    /// AI への受け渡しでは nil
    let action: SmartAction?
    /// nil なら `action` の実行の確認
    let request: AIRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if request != nil { destinationMenu }
            }
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let request {
                        Text(request.prompt.instruction)
                            .font(.system(size: 12, weight: .medium))
                        Divider()
                    }
                    Text(item.content)
                        .font(.system(size: 12, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            if request != nil {
                Toggle("今後は確認しない", isOn: $vm.dontAskAgain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if request != nil, vm.destinations.count > 1 {
                    Text("⇥ 送り先を切り替え").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                PanelButton(title: "キャンセル", key: "esc", action: vm.back)
                PanelButton(title: request != nil ? "送る" : action == .open ? "開く" : "実行", key: "↩", prominent: true, action: vm.confirm)
            }
        }
        .padding(8)
    }

    private var description: String {
        guard request != nil else {
            return action == .open
                ? String(localized: "Web ページ以外のリンクです。アプリの起動やファイルの実行につながることがあります。心当たりがある内容か確認してください。")
                : String(localized: "新しい Terminal ウインドウで次のコマンドを実行します。")
        }
        guard let destination = vm.selectedDestination else { return "" }
        switch destination.kind {
        case .app:
            return destination.autoSend
                ? String(localized: "\(destination.name) を開き、次の指示と本文 \(item.content.count) 文字を新しいチャットに貼り付けて送信します。")
                : String(localized: "\(destination.name) を開き、次の指示と本文 \(item.content.count) 文字を新しいチャットに貼り付けます。")
        case .url:
            return String(localized: "次の指示と本文 \(item.content.count) 文字を URL に入れて \(destination.name) を開きます。")
        }
    }

    private var destinationMenu: some View {
        Menu {
            ForEach(vm.destinations) { destination in
                Button { vm.destinationID = destination.id } label: {
                    Label(destination.name, systemImage: destination.systemImage)
                }
            }
        } label: {
            Text(vm.selectedDestination?.name ?? String(localized: "送り先"))
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct ResultView: View {
    let title: String
    let text: String
    let onPaste: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("⌘C でコピーのみ").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                PanelButton(title: "戻る", key: "esc", action: onBack)
                PanelButton(title: "貼り付け", key: "↩", prominent: true, action: onPaste)
            }
        }
        .padding(8)
    }
}

// MARK: - Parts

private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
    }
}

private struct PanelButton: View {
    let title: LocalizedStringKey
    let key: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).fontWeight(prominent ? .semibold : .regular)
                Text(key).opacity(prominent ? 0.8 : 0.55)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Theme.accent : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// メニューと同じ半透明の面・細い縁・影
    func popupSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.popupTint, in: shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }
}
