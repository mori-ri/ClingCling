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
    static let sectionHeight: CGFloat = 26
    private static let maxListHeight: CGFloat = 12 * rowHeight

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            panel
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layout.panelHeight = $0 }
            if vm.actionsOpen, case .list = vm.mode, let row = vm.selectedRow {
                ActionMenu(vm: vm, item: row.item, entries: vm.menuEntries(for: row),
                           preview: vm.model.thumbnail(for: row.item, maxPixelSize: 480, readingFiles: true))
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
                    if !vm.sections.isEmpty {
                        PanelDivider()
                        hints
                    }
                }
            case let .confirm(item, action, _):
                ConfirmView(vm: vm, item: item, title: Presentation.confirmationTitle(for: action, item: item),
                            systemImage: action.systemImage,
                            action: action, request: nil)
            case .confirmAI(let request):
                ConfirmView(vm: vm, item: request.item, title: request.title, systemImage: request.systemImage,
                            action: nil, request: request)
            case let .result(title, text):
                ResultView(title: title, text: text, onPaste: vm.pasteResult, onBack: vm.back)
            case .rename(let item):
                NameEditView(vm: vm, title: item.title == nil ? "別名を付ける" : "別名を変更",
                             systemImage: "character.cursor.ibeam", subject: Presentation.preview(item),
                             placeholder: "別名",
                             message: item.isPinned
                                ? "一覧には別名が出ます。貼り付けるのは元の内容です。空にすると別名を外します。"
                                : "一覧には別名が出ます。貼り付けるのは元の内容です。別名を付けるとピン留めになります。",
                             confirmTitle: "保存")
            case .chooseFolder(let item):
                FolderPickerView(vm: vm, item: item)
            case .renameFolder(let name):
                NameEditView(vm: vm, title: "フォルダ名を変更", systemImage: "folder", subject: name,
                             placeholder: "フォルダ名",
                             message: "同じ名前のフォルダがあれば、1 つにまとめます。",
                             confirmTitle: "変更")
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
                // 別名の入力などから戻ったときも、そのまま入力して絞り込めるように
                .onAppear { searchFocused = true }
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
        if vm.sections.isEmpty {
            emptyView
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.sections) { section in
                            if section.showsHeader { header(for: section) }
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { offset, row in
                                rowView(row, index: section.start + offset, inFolder: section.isFolder)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight)
                .onChange(of: vm.selection) { _, newValue in
                    // マウスで選んだ行は見えている。端の行で動かすと、スクロールして別の行が下に来てしまう。
                    guard !vm.selectedByPointer, vm.rows.indices.contains(newValue) else { return }
                    proxy.scrollTo(vm.rows[newValue].id)
                }
            }
        }
    }

    private func rowView(_ row: PopupViewModel.Row, index: Int, inFolder: Bool) -> some View {
        ClipRow(row: row, query: vm.query, thumbnail: vm.model.thumbnail(for: row.item),
                fileIcon: vm.model.fileIcon(for: row.item),
                selected: index == vm.selection,
                hovered: vm.hoveredID == row.id,
                onOpenActions: { vm.toggleActions(at: index) })
            // フォルダの中の行は少し下げて、どのフォルダに入っているかを分かりやすくする
            .padding(.leading, inFolder ? 12 : 0)
            .id(row.id)
            .background {
                if index == vm.selection {
                    Color.clear.onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named("popup")).minY
                    } action: { layout.selectedRowY = $0 }
                }
            }
            // プレビューを行の横に出すための位置
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
            // マウスを載せた行を選ぶ。動くたびに呼ばれるので、変わったときだけ書き込む。
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if vm.hoveredID != row.id { vm.hoveredID = row.id }
                    vm.pointerMoved(over: index)
                case .ended:
                    if vm.hoveredID == row.id { vm.hoveredID = nil }
                }
            }
    }

    @ViewBuilder
    private func header(for section: PopupViewModel.ListSection) -> some View {
        switch section.kind {
        case .pinned: sectionLabel("ピン留め")
        case .folder(let name): FolderHeader(vm: vm, name: name, count: section.count, collapsed: section.isCollapsed)
        case .recent: sectionLabel("履歴")
        }
    }

    /// 行数に合わせて縮む。多いときは 12 行分でスクロール。
    private var listHeight: CGFloat {
        let headers = vm.sections.filter(\.showsHeader).count
        let total = CGFloat(vm.rows.count) * Self.rowHeight + CGFloat(headers) * Self.sectionHeight
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
    /// ファイル Item の Finder のアイコン
    let fileIcon: NSImage?
    let selected: Bool
    let hovered: Bool
    let onOpenActions: () -> Void

    private var item: ClipItem { row.item }

    /// 本文。別名があれば別名を先に出し、本文は控えめに続ける
    private var label: Text {
        let content = Text(Presentation.highlighted(Presentation.preview(item), query: query,
                                                    masked: item.isFullyMasked, selected: selected))
            .font(.system(size: 13, design: Presentation.isMonospaced(item.contentType) ? .monospaced : .default))
        guard let title = item.title else { return content }
        return Text(Presentation.highlighted(title, query: query, masked: false, selected: selected))
            .font(.system(size: 13, weight: .medium))
            + Text(verbatim: "  ")
            + content.foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
    }

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
            } else if let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: Presentation.rowIcon(for: item))
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }

            label
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tag = Presentation.tag(item) {
                Text(tag)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }

            // 選択中の行と、マウスを載せた行（アクションメニューを開いている間など）に出す
            if selected || hovered {
                Button(action: onOpenActions) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
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
        .accessibilityHint(Presentation.meta(item))
    }
}

// MARK: - Action menu

struct ActionMenu: View {
    @ObservedObject var vm: PopupViewModel
    /// メニューを開いている Item（Action 名を Item に合わせる）
    let item: ClipItem
    let entries: [PopupViewModel.MenuEntry]
    /// 画像 Item（画像のファイルを含む）のプレビュー
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
        case .smart(let action, _): Presentation.title(for: action, item: item)
        case .custom(let custom, _): custom.name
        case .save: Presentation.title(for: .saveImage)
        case .pin(let isPinned): isPinned ? String(localized: "ピン留めを外す") : String(localized: "ピン留めする")
        case .rename(let hasTitle): hasTitle ? String(localized: "別名を変更") : String(localized: "別名を付ける")
        case .folder(let inFolder): inFolder ? String(localized: "フォルダを移動") : String(localized: "フォルダに入れる")
        case .delete: String(localized: "削除")
        }
    }

    private func icon(for entry: PopupViewModel.MenuEntry) -> String {
        switch entry {
        case .paste: "doc.on.clipboard"
        case .smart(let action, _): action.systemImage
        case .custom: CustomAIAction.systemImage
        case .save: SmartAction.saveImage.systemImage
        case .pin(let isPinned): isPinned ? "pin.slash" : "pin"
        case .rename: "character.cursor.ibeam"
        case .folder(let inFolder): inFolder ? "folder" : "folder.badge.plus"
        case .delete: "trash"
        }
    }

    private func shortcut(for entry: PopupViewModel.MenuEntry) -> String {
        switch entry {
        case .paste: "↩"
        case .smart(_, let n): "⌘\(n)"
        case .custom(_, let n): n.map { "⌘\($0)" } ?? ""
        case .save: "⌘S"
        case .pin: "⌘P"
        case .rename: "⌘R"
        case .folder: ""
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
                PanelButton(title: confirmTitle, key: "↩", prominent: true, action: vm.confirm)
            }
        }
        .padding(8)
    }

    private var confirmTitle: LocalizedStringKey {
        if request != nil { return "送る" }
        switch action {
        case .open, .openFile: return "開く"
        default: return "実行"
        }
    }

    private var description: String {
        guard request != nil else {
            switch action {
            case .open:
                return String(localized: "Web ページ以外のリンクです。アプリの起動やファイルの実行につながることがあります。心当たりがある内容か確認してください。")
            case .openFile:
                return Presentation.openFileWarning(item)
            default:
                return String(localized: "新しい Terminal ウインドウで次のコマンドを実行します。")
            }
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

// MARK: - Folders

/// ピン留めのフォルダの見出し。クリックで畳む・開く。名前の変更と解除は … のメニューか右クリック。
private struct FolderHeader: View {
    @ObservedObject var vm: PopupViewModel
    let name: String
    let count: Int
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
            Spacer(minLength: 4)
            Menu { actions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("フォルダの操作")
            .accessibilityLabel("フォルダの操作")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: PopupView.sectionHeight)
        .contentShape(Rectangle())
        .onTapGesture { vm.toggleFolder(name) }
        .contextMenu { actions }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(hint))
    }

    private var hint: LocalizedStringKey { collapsed ? "クリックで開きます" : "クリックで畳みます" }

    @ViewBuilder
    private var actions: some View {
        Button("フォルダ名を変更…") { vm.startRenameFolder(name) }
        Button("フォルダを解除") { vm.removeFolder(name) }
    }
}

/// 別名・フォルダ名の入力
struct NameEditView: View {
    @ObservedObject var vm: PopupViewModel
    let title: LocalizedStringKey
    let systemImage: String
    /// 何に名前を付けるか（Item の本文や、今のフォルダ名）
    let subject: String
    let placeholder: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Text(subject)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            PanelTextField(placeholder: placeholder, text: $vm.draft, focused: $focused)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                PanelButton(title: "キャンセル", key: "esc", action: vm.back)
                PanelButton(title: confirmTitle, key: "↩", prominent: true, action: vm.commitEdit)
            }
        }
        .padding(8)
        .onAppear { focused = true }
    }
}

/// ピン留めを入れるフォルダの選択。入力した文字でフォルダを絞り込み、無ければ新しく作る。
struct FolderPickerView: View {
    @ObservedObject var vm: PopupViewModel
    let item: ClipItem
    @FocusState private var focused: Bool

    private static let optionHeight: CGFloat = 26

    private var heading: LocalizedStringKey { item.folder == nil ? "フォルダに入れる" : "フォルダを移動" }

    var body: some View {
        let options = vm.folderOptions(for: item)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let folder = item.folder {
                    Text("今: \(folder)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(item.title ?? Presentation.preview(item))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            PanelTextField(placeholder: "フォルダを探す・新しく作る", text: $vm.draft, focused: $focused)
            if options.isEmpty {
                // 候補が無いのは、何も入力していないか、今入っているフォルダの名前を入力したとき
                Text(PinFolders.normalizedFolder(vm.draft) == nil
                     ? "フォルダの名前を入力すると、新しいフォルダを作れます。" : "今入っているフォルダです。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                                Button { vm.chooseFolderOption(option) } label: {
                                    label(for: option, highlighted: index == vm.folderIndex)
                                }
                                .buttonStyle(.plain)
                                .onHover { if $0 { vm.folderIndex = index } }
                                .id(index)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(options.count), 7) * Self.optionHeight)
                    .onChange(of: vm.folderIndex) { _, newValue in proxy.scrollTo(newValue) }
                }
            }
            if !item.isPinned {
                Text("フォルダに入れるとピン留めになります。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if options.count > 1 {
                    Text("↑↓ 選択").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                PanelButton(title: "キャンセル", key: "esc", action: vm.back)
                PanelButton(title: "移動", key: "↩", prominent: true, action: vm.commitEdit)
            }
        }
        .padding(8)
        .onAppear { focused = true }
    }

    private func label(for option: PopupViewModel.FolderOption, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: option))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            title(for: option)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.optionHeight)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Theme.accent : .clear)
        )
        .contentShape(Rectangle())
    }

    private func title(for option: PopupViewModel.FolderOption) -> Text {
        switch option {
        case .existing(let name): Text(verbatim: name)
        case .create(let name): Text("「\(name)」を作る")
        case .remove: Text("フォルダから出す")
        }
    }

    private func icon(for option: PopupViewModel.FolderOption) -> String {
        switch option {
        case .existing: "folder"
        case .create: "folder.badge.plus"
        case .remove: "folder.badge.minus"
        }
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

/// 別名・フォルダ名の入力欄
private struct PanelTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused(focused)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
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
        popupFill(cornerRadius: cornerRadius)
            .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }

    /// `popupSurface` の影のない面
    func popupFill(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.popupTint, in: shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
