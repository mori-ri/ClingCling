import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClingClingCore
import Combine

/// ⌘⇧V ポップアップの状態
@MainActor
final class PopupViewModel: ObservableObject {
    enum Mode {
        case list
        /// Run や、Web 以外の URL、アプリやスクリプトのファイルを開く前の確認
        case confirm(item: ClipItem, action: SmartAction, position: Int)
        /// AI に渡す前の確認
        case confirmAI(AIRequest)
        case result(title: String, text: String)
    }

    /// 一覧の区切り。通常時は ピン留め（フォルダ → フォルダの外）→ 履歴 の順、検索中は 1 つだけ。
    struct ListSection: Identifiable {
        enum Kind: Hashable {
            /// ピン留め（フォルダに入っていないものと、フォルダの行）
            case pinned
            case recent
        }

        let kind: Kind
        /// 見出しを出すか（検索中と、ピン留めが無いときの履歴は出さない）
        let showsHeader: Bool
        let lines: [Line]
        var id: Kind { kind }
    }

    /// 一覧の 1 行。フォルダはアコーディオンで、開いていれば中の Item がすぐ下に続く。
    enum Line: Identifiable {
        /// `index` は `rows` での位置。`indented` はフォルダの中の行
        case row(Row, index: Int, indented: Bool)
        case folder(Folder, expanded: Bool)

        var id: String {
            switch self {
            case .row(let row, _, _): row.id.uuidString
            case .folder(let folder, _): folder.id
            }
        }
    }

    /// ピン留めのフォルダ
    struct Folder: Identifiable {
        let name: String
        let rows: [Row]
        var id: String { "folder:" + name }
    }

    struct Row: Identifiable {
        let item: ClipItem
        let actions: [SmartAction]
        /// 数字キーで貼り付けられる番号（履歴の先頭 9 件のみ）
        let number: Int?
        var id: UUID { item.id }

        /// アクションメニューに出す Smart Action。Copy は「貼り付け」と重複するので除く。
        var smartActions: [SmartAction] { actions.filter { $0 != .copy } }
    }

    /// 選択中の行から右に開くアクションメニューの項目
    enum MenuEntry: Hashable {
        case paste
        /// `shortcut` は ⌘1–3 の番号
        case smart(SmartAction, shortcut: Int)
        /// 自作の AI Action。`shortcut` は ⌘4–9 の番号（7 個目以降は無し）
        case custom(CustomAIAction, shortcut: Int?)
        /// 「ダウンロード」にファイルで保存（⌘S）
        case save
        case pin(isPinned: Bool)
        /// 設定のピン留めのページで、別名・フォルダ・並び順を変える
        case organize
        case delete

        var group: Int {
            switch self {
            case .paste: 0
            case .smart: 1
            case .custom: 2
            case .save, .pin, .organize, .delete: 3
            }
        }

        /// 本文を AI に渡す項目か（メニューに印を付ける）
        var usesAI: Bool {
            switch self {
            case .smart(let action, _): action.usesAI
            case .custom: true
            default: false
            }
        }
    }

    @Published var query = "" { didSet { reload(resetSelection: true) } }
    /// すべての Item の行（閉じたフォルダの中も含む）。`selection` はこの中の位置
    @Published private(set) var rows: [Row] = []
    /// 選んでいるフォルダの行。選んでいる間は `selectedRow` が nil
    @Published private(set) var selectedFolder: String? {
        didSet {
            guard selectedFolder != oldValue else { return }
            selectedByPointer = false
            pointerLocationAtSelection = NSEvent.mouseLocation
            actionsOpen = false
        }
    }
    @Published private(set) var sections: [ListSection] = []
    /// 開いているフォルダ（`reload` で読む）
    private var openFolders: Set<String> = []
    @Published var selection = 0 {
        didSet {
            selectedByPointer = false
            pointerLocationAtSelection = NSEvent.mouseLocation
            if selection != oldValue { actionsOpen = false }
        }
    }
    /// 直前の選択はマウスを載せて選んだもの（見えている行なので、スクロールで追わない）
    private(set) var selectedByPointer = false
    /// 選択を変えたときのマウスの位置。マウスを動かさないまま行が下に来ただけ
    /// （マウスの位置に開いた直後、キーボードでの移動によるスクロール）では選ばない。
    private var pointerLocationAtSelection: CGPoint?
    @Published var mode: Mode = .list { didSet { if case .list = mode {} else { hidePreview() } } }
    @Published var notice: String?
    @Published var dontAskAgain = false
    @Published var hoveredID: UUID? { didSet { if hoveredID != oldValue { schedulePreview() } } }
    /// マウスを載せている行の位置（"popup" 座標系）。プレビューを行の横に出すのに使う。
    var hoveredRowFrame: CGRect = .zero { didSet { if hoveredRowFrame != oldValue { movePreview() } } }
    /// マウスを載せている Item のプレビュー
    @Published private(set) var preview: Preview?
    /// マウスがプレビューのカードの上にある（長い本文をスクロールしている間は閉じない）
    var previewHovered = false { didSet { if previewHovered != oldValue { schedulePreview() } } }
    @Published var actionsOpen = false {
        didSet {
            if actionsOpen != oldValue { actionIndex = 0 }
            // アクションメニューにもプレビューが出るので重ねない
            if actionsOpen { hidePreview() }
        }
    }
    @Published var actionIndex = 0
    /// 確認画面で選んでいる AI の送り先
    @Published var destinationID: UUID?

    struct Preview: Equatable {
        let item: ClipItem
        /// 行の位置（"popup" 座標系）
        let rowFrame: CGRect
    }

    private var previewTask: Task<Void, Never>?

    let model: AppModel
    /// ポップアップを閉じる（`paste` なら直前のアプリへ貼り付け）
    var close: (_ paste: Bool) -> Void = { _ in }
    var openSettings: () -> Void = {}
    /// 設定のピン留めのページを開き、この Item を選ぶ
    var showPinnedInSettings: (ClipItem) -> Void = { _ in }

    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        model.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload(resetSelection: false) }
        }.store(in: &cancellables)
    }

    /// ポップアップを開くたびに呼ぶ
    func prepare() {
        mode = .list
        notice = nil
        actionsOpen = false
        hoveredID = nil
        hidePreview()
        pointerLocationAtSelection = NSEvent.mouseLocation
        if query.isEmpty { reload(resetSelection: true) } else { query = "" }
    }

    func reload(resetSelection: Bool) {
        let selectedID = selectedRow?.id
        let items = model.items(query: query, pinnedOnly: false)
        var built: [ListSection] = []
        var allRows: [Row] = []
        var builtFolders: [String] = []
        func makeRows(_ items: [ClipItem], numbered: Bool = false) -> [(Row, Int)] {
            items.enumerated().map { offset, item in
                let row = Row(item: item, actions: model.actions(for: item),
                              number: numbered && offset < 9 ? offset + 1 : nil)
                allRows.append(row)
                return (row, allRows.count - 1)
            }
        }
        if query.isEmpty {
            // 通常時はピン留めを上に。設定と同じく、フォルダの行（設定で決めた順）、続いてフォルダに入っていないもの
            openFolders = model.openFolders()
            let groups = PinFolders.group(model.pinnedItems(), folderOrder: model.folders())
            if !groups.isEmpty {
                var lines: [Line] = []
                for group in groups {
                    let made = makeRows(group.items)
                    if let name = group.folder {
                        let folder = Folder(name: name, rows: made.map(\.0))
                        let expanded = isExpanded(name)
                        builtFolders.append(name)
                        lines.append(.folder(folder, expanded: expanded))
                        if expanded { lines += made.map { Line.row($0.0, index: $0.1, indented: true) } }
                    } else {
                        lines += made.map { Line.row($0.0, index: $0.1, indented: false) }
                    }
                }
                built.append(ListSection(kind: .pinned, showsHeader: true, lines: lines))
            }
            let recent = items.filter { !$0.isPinned }
            if !recent.isEmpty {
                built.append(ListSection(kind: .recent, showsHeader: !groups.isEmpty,
                                         lines: makeRows(recent, numbered: true).map { Line.row($0.0, index: $0.1, indented: false) }))
            }
        } else if !items.isEmpty {
            // 検索中は区切らず新しい順。フォルダの中の Item も並べる
            built.append(ListSection(kind: .recent, showsHeader: false,
                                     lines: makeRows(items, numbered: true).map { Line.row($0.0, index: $0.1, indented: false) }))
        }
        sections = built
        rows = allRows
        // 新しくコピーした Item やピン留めで行が動いても、同じ Item・フォルダを選んだままにする
        if resetSelection {
            selectedFolder = nil
            // 開いたときは最後にコピーしたもの（履歴の先頭）を選ぶ。ピン留めは上にあるが選ばない
            let recent = built.first { $0.kind == .recent }?.lines.first
            if case .row(_, let index, _) = recent { selection = index } else { selectFirstLine() }
        } else {
            if let name = selectedFolder, !builtFolders.contains(name) { selectFirstLine() }
            if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
                selection = index
                // 閉じたフォルダの中に入った Item なら、そのフォルダを選ぶ
                if !isVisible(index), let folder = rows[index].item.folder, builtFolders.contains(folder) {
                    selectedFolder = folder
                }
            }
        }
        selection = min(selection, max(rows.count - 1, 0))
        // 削除などで、選んでいた位置が閉じたフォルダの中になったら選び直す
        if selectedFolder == nil, !rows.isEmpty, !isVisible(selection) { selectFirstLine() }
        if rows.isEmpty { actionsOpen = false }
        // 削除などで行が消えたらプレビューも閉じる
        if let preview, !rows.contains(where: { $0.id == preview.item.id }) { hidePreview() }
    }

    /// 選んでいる Item。フォルダの行を選んでいるときは nil
    var selectedRow: Row? {
        guard selectedFolder == nil, rows.indices.contains(selection) else { return nil }
        return rows[selection]
    }

    /// キーボードで上下に動く行の並び（開いているフォルダの中を含む）
    private var navigation: [Line] { sections.flatMap(\.lines) }

    /// 今選んでいる行の `navigation` での位置
    private var navigationIndex: Int? {
        navigation.firstIndex { line in
            switch line {
            case .folder(let folder, _): folder.name == selectedFolder
            case .row(_, let index, _): selectedFolder == nil && index == selection
            }
        }
    }

    /// その行が一覧に出ているか（閉じたフォルダの中でないか）
    private func isVisible(_ index: Int) -> Bool {
        navigation.contains { if case .row(_, index, _) = $0 { true } else { false } }
    }

    private func selectFirstLine() {
        switch navigation.first {
        case .folder(let folder, _)?: selectedFolder = folder.name
        case .row(_, let index, _)?:
            selectedFolder = nil
            selection = index
        case nil:
            selectedFolder = nil
            selection = 0
        }
    }

    private func select(row index: Int) {
        selectedFolder = nil
        selection = index
    }

    // MARK: - Folders

    func isExpanded(_ name: String) -> Bool {
        openFolders.contains(name)
    }

    /// フォルダを開く・閉じる（その行を選ぶ）。開いたかどうかは次にポップアップを開いたときも残す
    func toggleFolder(_ name: String) {
        setExpanded(name, !isExpanded(name))
    }

    func setExpanded(_ name: String, _ expanded: Bool) {
        selectedFolder = name
        guard expanded != isExpanded(name) else { return }
        model.setFolderOpen(name, expanded)
        reload(resetSelection: false)
    }

    /// フォルダの行にマウスを載せたら、その行を選ぶ（Item の行と同じ）
    func pointerOverFolder(_ name: String) {
        guard !actionsOpen, case .list = mode, selectedFolder != name else { return }
        guard NSEvent.mouseLocation != pointerLocationAtSelection else { return }
        selectedFolder = name
        selectedByPointer = true
    }

    /// →。閉じたフォルダは開き、開いたフォルダでは中の先頭の Item へ
    private func enterFolder(_ name: String) {
        guard isExpanded(name) else {
            setExpanded(name, true)
            return
        }
        let first = navigation.first { if case .row(let row, _, true) = $0 { row.item.folder == name } else { false } }
        if case .row(_, let index, _)? = first { select(row: index) }
    }

    /// ←。開いたフォルダは閉じ、フォルダの中の Item ではそのフォルダの行へ。何もしなければ false
    private func leaveFolder() -> Bool {
        if let name = selectedFolder {
            guard isExpanded(name) else { return false }
            setExpanded(name, false)
            return true
        }
        guard query.isEmpty, let folder = selectedRow?.item.folder, isExpanded(folder) else { return false }
        selectedFolder = folder
        return true
    }

    // MARK: - Preview

    /// 行にマウスを少し留めたらプレビューを出す。通り過ぎるだけでは出さない。
    /// 開いているときも少し待つ。すぐに切り替えると、カードへ斜めに動かす途中の行に変わってしまう。
    /// 閉じるのはさらに待つ。行の端からカードまでの隙間をゆっくり横切っても閉じないように。
    private func schedulePreview() {
        previewTask?.cancel()
        guard !previewHovered else { return }
        guard !actionsOpen, case .list = mode else {
            hidePreview()
            return
        }
        let delay = preview == nil ? 250 : hoveredID == nil ? 400 : 150
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            let item = self.rows.first { $0.id == self.hoveredID }?.item
            self.preview = item.map { Preview(item: $0, rowFrame: self.hoveredRowFrame) }
        }
    }

    private func movePreview() {
        guard let preview, preview.item.id == hoveredID else { return }
        self.preview = Preview(item: preview.item, rowFrame: hoveredRowFrame)
    }

    private func hidePreview() {
        previewHovered = false
        previewTask?.cancel()
        previewTask = nil
        if preview != nil { preview = nil }
    }

    /// 行の上でマウスが動いたら、その行を選ぶ（ハイライトして › からアクションメニューを開けるように）。
    /// アクションメニューを開いている間は選び直さない。メニューへ斜めにマウスを動かす途中で閉じてしまうので。
    func pointerMoved(over index: Int) {
        guard !actionsOpen, case .list = mode, rows.indices.contains(index) else { return }
        guard selectedFolder != nil || selection != index else { return }
        guard NSEvent.mouseLocation != pointerLocationAtSelection else { return }
        select(row: index)
        selectedByPointer = true
    }

    /// ↑↓。開いているフォルダの中の行も順に通る
    func moveSelection(_ delta: Int) {
        let lines = navigation
        guard !lines.isEmpty else { return }
        let current = navigationIndex ?? 0
        switch lines[max(0, min(lines.count - 1, current + delta))] {
        case .folder(let folder, _): selectedFolder = folder.name
        case .row(_, let index, _): select(row: index)
        }
    }

    // MARK: - Action menu

    func menuEntries(for row: Row) -> [MenuEntry] {
        var entries: [MenuEntry] = [.paste]
        entries += row.smartActions.prefix(3).enumerated().map { .smart($1, shortcut: $0 + 1) }
        entries += customActions(for: row.item).enumerated().map { .custom($1, shortcut: $0 < 6 ? $0 + 4 : nil) }
        // 画像は Smart Action の「ダウンロードに保存」が並ぶので重ねない
        if ExportFile.canExport(row.item) && !row.smartActions.contains(.saveImage) { entries.append(.save) }
        if !row.item.isTemporary {
            entries.append(.pin(isPinned: row.item.isPinned))
            if row.item.isPinned { entries.append(.organize) }
        }
        entries.append(.delete)
        return entries
    }

    /// 自作の AI Action は、AI への受け渡しが有効で外部送信できる Item にだけ出す
    func customActions(for item: ClipItem) -> [CustomAIAction] {
        guard model.settings.externalAIEnabled, item.externalAllowed else { return [] }
        return model.settings.customAIActions.filter {
            !$0.name.isEmpty && !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func openActions() {
        // フォルダの行では、開くか中の Item へ
        if let name = selectedFolder {
            enterFolder(name)
            return
        }
        guard selectedRow != nil else { return }
        actionsOpen = true
    }

    func toggleActions(at index: Int) {
        if selectedFolder == nil && selection == index && actionsOpen {
            actionsOpen = false
            return
        }
        select(row: index)
        actionsOpen = true
    }

    func moveActionIndex(_ delta: Int) {
        guard let row = selectedRow else { return }
        let count = menuEntries(for: row).count
        actionIndex = max(0, min(count - 1, actionIndex + delta))
    }

    func performMenuEntry(_ index: Int) {
        guard let row = selectedRow else { return }
        let entries = menuEntries(for: row)
        guard entries.indices.contains(index) else { return }
        actionsOpen = false
        switch entries[index] {
        case .paste: paste(row.item)
        case .smart(_, let shortcut): performSmart(shortcut - 1)
        case .custom(let custom, _): startAI(AIHandoff.request(for: custom, item: row.item))
        case .save: saveSelected()
        case .pin: togglePinSelected()
        case .organize: openPinnedSettings(row.item)
        case .delete: deleteSelected()
        }
    }

    /// 選択中の行の n 番目（0 始まり）の Smart Action（⌘1–3）
    func performSmart(_ index: Int) {
        guard let row = selectedRow, row.smartActions.indices.contains(index) else { return }
        let action = row.smartActions[index]
        // 学習には Action Ranker 上の表示位置を使う
        perform(action, on: row.item, position: row.actions.firstIndex(of: action) ?? index)
    }

    /// 選択中の行の n 番目（0 始まり）の自作 AI Action（⌘4–9）
    func performCustom(_ index: Int) {
        guard let row = selectedRow else { return }
        let customs = customActions(for: row.item)
        guard customs.indices.contains(index) else { return }
        notice = nil
        actionsOpen = false
        startAI(AIHandoff.request(for: customs[index], item: row.item))
    }

    // MARK: - Actions

    /// `position` は Action Ranker 上の位置（0 = 最も推奨）。First Action Selection Rate の計測に使う。
    func perform(_ action: SmartAction, on item: ClipItem, position: Int) {
        notice = nil
        actionsOpen = false
        if action.usesAI {
            guard let request = AIHandoff.request(for: action, position: position, item: item, settings: model.settings)
            else { return }
            startAI(request)
            return
        }
        if action.needsConfirmation(for: item.content) {
            mode = .confirm(item: item, action: action, position: position)
            return
        }
        execute(action, item: item, position: position)
    }

    /// 履歴からのワンクリック貼り付け。クリップボードに書き戻して閉じ、直前のアプリへ ⌘V を送る。
    func paste(_ item: ClipItem) {
        notice = nil
        // 画像やファイルが見つからなければ、前のクリップボードの内容を貼ってしまわないよう止める
        guard model.writeItemToPasteboard(item) else {
            mode = .list
            notice = ActionExecutor.notFoundMessage(for: item)
            return
        }
        // 「Copy を選んだ」として学習する（表示位置は Copy の位置。無ければ末尾扱い）
        let row = rows.first { $0.id == item.id }
        model.recordAction(.copy, item: item, position: row?.actions.firstIndex(of: .copy) ?? ActionRanker.maxVisible)
        pasteWrittenContent()
    }

    func pasteSelected() {
        guard let row = selectedRow else { return }
        paste(row.item)
    }

    /// 履歴の n 番（1–9）を貼り付ける
    func paste(number: Int) {
        guard let index = rows.firstIndex(where: { $0.number == number }) else { return }
        select(row: index)
        paste(rows[index].item)
    }

    private func pasteText(_ text: String) {
        notice = nil
        model.writeToPasteboard(text)
        pasteWrittenContent()
    }

    /// クリップボードに書いた内容を直前のアプリへ貼り付ける（権限が無ければ案内だけ出す）
    private func pasteWrittenContent() {
        guard ActionExecutor.requestAccessibility() else {
            mode = .list
            notice = String(localized: "コピーしました（⌘V で貼り付けできます）。自動で貼り付けるには、システム設定 → プライバシーとセキュリティ → アクセシビリティ で ClingCling を許可してください。")
            return
        }
        // Secure Input の間は、合成したキー入力がシステムに捨てられる
        guard !IsSecureEventInputEnabled() else {
            mode = .list
            notice = String(localized: "コピーしました（⌘V で貼り付けできます）。パスワードの入力中など、入力が保護されている間は自動で貼り付けできません。")
            return
        }
        close(true)
    }

    private func execute(_ action: SmartAction, item: ClipItem, position: Int) {
        model.recordAction(action, item: item, position: position)
        handle(ActionExecutor.perform(action, on: item, model: model))
    }

    private func handle(_ outcome: ActionExecutor.Outcome) {
        switch outcome {
        case .close(let paste):
            if paste { pasteWrittenContent() } else { close(false) }
        case .show(let title, let text): mode = .result(title: title, text: text)
        case .failure(let message):
            mode = .list
            notice = message
        }
    }

    private func startAI(_ request: AIRequest) {
        // 二重チェック: Local only の Item は UI に出ないが、念のためここでも止める
        guard request.item.externalAllowed else {
            notice = String(localized: "この Item は Local only です。")
            return
        }
        guard model.settings.externalAIEnabled else {
            notice = String(localized: "AI への受け渡しは無効です。設定 › AI で有効にできます。")
            return
        }
        // 自作 Action の送り先が削除されていたら既定の送り先に戻す
        guard let destination = destinations.first(where: { $0.id == request.destinationID })
                ?? model.settings.defaultDestination else {
            notice = String(localized: "AI の送り先がありません。設定 › AI で追加してください。")
            return
        }
        destinationID = destination.id
        if model.settings.confirmAISend {
            dontAskAgain = false
            mode = .confirmAI(request)
        } else {
            sendToAI(request, destination: destination)
        }
    }

    var destinations: [AIDestination] { model.settings.aiDestinations }

    var selectedDestination: AIDestination? {
        destinations.first { $0.id == destinationID } ?? model.settings.defaultDestination
    }

    /// 確認画面で送り先を切り替える（⇥）
    func cycleDestination() {
        let all = destinations
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == selectedDestination?.id } ?? -1
        destinationID = all[(index + 1) % all.count].id
    }

    func confirm() {
        switch mode {
        case let .confirm(item, action, position):
            execute(action, item: item, position: position)
        case .confirmAI(let request):
            guard let destination = selectedDestination else { return }
            if dontAskAgain { model.settings.confirmAISend = false }
            sendToAI(request, destination: destination)
        default:
            break
        }
    }

    private func sendToAI(_ request: AIRequest, destination: AIDestination) {
        // 送り先のアプリを前面に出すので、先にポップアップを閉じる
        close(false)
        do {
            try AIHandoff.send(request, to: destination, model: model)
            if let learning = request.learning {
                model.recordAction(learning.action, item: request.item, position: learning.position)
            }
        } catch {
            // 失敗はポップアップを開き直さず、アラートで知らせる
            let alert = NSAlert()
            alert.messageText = String(localized: "\(destination.name) に送れませんでした")
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    func back() {
        mode = .list
    }

    /// 結果を直前のアプリへ貼り付ける
    func pasteResult() {
        guard case let .result(_, text) = mode else { return }
        pasteText(text)
    }

    func copyResult() {
        guard case let .result(_, text) = mode else { return }
        model.writeToPasteboard(text)
        close(false)
    }

    func togglePinSelected() {
        guard let row = selectedRow else { return }
        if row.item.isTemporary {
            notice = String(localized: "Sensitive な一時 Item は Pin できません。")
            return
        }
        model.togglePin(row.item)
    }

    /// 選択中の Item を「ダウンロード」にファイルで保存する（⌘S）
    func saveSelected() {
        guard let row = selectedRow else { return }
        notice = nil
        actionsOpen = false
        // 画像は Smart Action として学習させる
        if let position = row.actions.firstIndex(of: .saveImage) {
            perform(.saveImage, on: row.item, position: position)
            return
        }
        handle(ActionExecutor.saveFile(row.item, model: model))
    }

    func deleteSelected() {
        guard let row = selectedRow else { return }
        model.delete(row.item)
    }

    // MARK: - Pinned

    /// 別名・フォルダ・並び順は設定で変える。ポップアップは選んで貼り付けるだけにする
    func openPinnedSettings(_ item: ClipItem) {
        actionsOpen = false
        showPinnedInSettings(item)
    }

    // MARK: - Keyboard

    /// NSEvent の keyDown を処理する。処理したら true。
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch mode {
        case .list:
            switch event.keyCode {
            case 53: // esc
                if actionsOpen {
                    actionsOpen = false
                } else if !query.isEmpty {
                    query = ""
                } else {
                    close(false)
                }
                return true
            case 125: // ↓
                if actionsOpen { moveActionIndex(1) } else { moveSelection(1) }
                return true
            case 126: // ↑
                if actionsOpen { moveActionIndex(-1) } else { moveSelection(-1) }
                return true
            case 124: // →
                openActions()
                return true
            case 123: // ←
                if actionsOpen {
                    actionsOpen = false
                    return true
                }
                return leaveFolder()
            case 36, 76: // return / enter
                if actionsOpen {
                    performMenuEntry(actionIndex)
                } else if let name = selectedFolder {
                    toggleFolder(name)
                } else {
                    pasteSelected()
                }
                return true
            case 51 where cmd: // ⌘⌫
                deleteSelected()
                return true
            default: break
            }
            if cmd, let n = Int(key), (1...3).contains(n) {
                performSmart(n - 1)
                return true
            }
            if cmd, let n = Int(key), (4...9).contains(n) {
                performCustom(n - 4)
                return true
            }
            if cmd, key == "p" {
                togglePinSelected()
                return true
            }
            if cmd, key == "s" {
                saveSelected()
                return true
            }
            if cmd, key == "," {
                openSettings()
                return true
            }
            // 検索語が空のときだけ、数字キーで履歴の n 番を貼り付ける（入力中は数字も検索語になる）
            if flags.subtracting([.numericPad, .function]).isEmpty, query.isEmpty, !actionsOpen,
               let n = Int(key), (1...9).contains(n) {
                paste(number: n)
                return true
            }
            return false

        case .confirm, .confirmAI:
            switch event.keyCode {
            case 36, 76: confirm(); return true
            case 53: back(); return true
            case 48: // ⇥
                guard case .confirmAI = mode else { return false }
                cycleDestination()
                return true
            default: return false
            }

        case .result:
            switch event.keyCode {
            case 36, 76: pasteResult(); return true
            case 53: back(); return true
            default:
                if cmd, key == "c" { copyResult(); return true }
                return false
            }
        }
    }
}
