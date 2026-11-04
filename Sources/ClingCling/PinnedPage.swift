import AppKit
import ClingClingCore
import SwiftUI
import UniformTypeIdentifiers

/// 設定のピン留めのページ。Finder のリスト表示のように、1 つの一覧でピン留めを扱う。
///
/// - 上にフォルダ、続いてフォルダに入っていない Item。フォルダはアコーディオンで、その場で開閉する（中へは移動しない）
/// - クリックで選択（⌘ で追加、⇧ で範囲）。ダブルクリックで Item の編集、↩ で名前の変更、⌫ で削除
/// - ドラッグで並べ替え。フォルダの行に落とすとそのフォルダへ、フォルダの中の行の間に落とすとそこへ、
///   フォルダの外の行の間や一覧の下に落とすとフォルダから出る
///
/// ピン留めの整理はここでだけ行い、ポップアップは選んで貼り付けるだけにする。
struct PinnedPage: View {
    /// 履歴が変わるたび（ポップアップでの操作を含む）に一覧を読み直す
    @ObservedObject var model: AppModel
    @ObservedObject var form: SettingsFormState
    @StateObject private var browser: PinnedBrowser
    @FocusState private var listFocused: Bool

    init(model: AppModel, form: SettingsFormState) {
        self.model = model
        self.form = form
        _browser = StateObject(wrappedValue: PinnedBrowser(model: model))
    }

    var body: some View {
        let listing = browser.listing()
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            PinnedToolbar(browser: browser, listing: listing)
            Theme.separator.frame(height: 1)
            ColumnHeader(searching: listing.searching)
            Theme.separator.frame(height: 1)
            list(listing)
            Theme.separator.frame(height: 1)
            StatusBar(browser: browser, listing: listing)
        }
        .background(Theme.cardFill)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .sheet(item: $browser.editing) { item in
            ItemEditor(item: item, model: model) { browser.editing = nil }
        }
        .confirmationDialog(browser.deleteTitle, isPresented: $browser.confirmingDelete) {
            Button("削除", role: .destructive) { browser.performDelete() }
        } message: {
            Text(browser.deleteMessage)
        }
        .onAppear {
            browser.reveal(form.pinnedSelection)
            form.pinnedSelection = nil
            listFocused = true
        }
        .onChange(of: form.pinnedSelection) { _, id in
            guard id != nil else { return }
            browser.reveal(id)
            form.pinnedSelection = nil
        }
        .onChange(of: model.revision) { _, _ in browser.tidy() }
    }

    private func list(_ listing: PinnedListing) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listing.entries) { entry in
                        EntryRow(browser: browser, entry: entry, listing: listing, listFocused: listFocused) {
                            listFocused = true
                        }
                        .id(entry.key)
                    }
                    // 一覧の下の余白。クリックで選択を外し、Item を落とすと一番下へ
                    Color.clear
                        .frame(height: 60)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            if browser.dropIndicator == .end { InsertionLine() }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            browser.selection = []
                            listFocused = true
                        }
                        .onDrop(of: [.utf8PlainText], delegate: PinnedDrop(browser: browser, target: .end, listing: listing))
                        .contextMenu { BackgroundMenu(browser: browser, listing: listing) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .overlay {
                if listing.entries.isEmpty { EmptyMessage(listing: listing) }
            }
            .onChange(of: browser.revealed) { _, key in
                guard let key else { return }
                proxy.scrollTo(key, anchor: .center)
                browser.revealed = nil
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            browser.handleKey(press, listing: listing) ? .handled : .ignored
        }
    }
}

// MARK: - Model

/// 一覧の 1 行の識別子（選択やドラッグに使う）
enum PinnedKey: Hashable {
    case folder(String)
    case item(UUID)

    var folderName: String? {
        if case .folder(let name) = self { return name }
        return nil
    }

    var itemID: UUID? {
        if case .item(let id) = self { return id }
        return nil
    }
}

/// 一覧の 1 行
enum PinnedEntry: Identifiable {
    case folder(name: String, count: Int, expanded: Bool)
    /// `inFolder` は開いたフォルダの中の行（左を下げる）
    case item(ClipItem, inFolder: Bool)

    var key: PinnedKey {
        switch self {
        case .folder(let name, _, _): .folder(name)
        case .item(let item, _): .item(item.id)
        }
    }

    var id: PinnedKey { key }

    var item: ClipItem? {
        if case .item(let item, _) = self { return item }
        return nil
    }
}

/// 一覧の中身
struct PinnedListing {
    let searching: Bool
    let entries: [PinnedEntry]
    /// 並べているフォルダ（まだ Item の無いフォルダも含む）
    let folders: [String]
    /// フォルダに入っていない Item
    let loose: [ClipItem]

    func entries(for keys: Set<PinnedKey>) -> [PinnedEntry] {
        entries.filter { keys.contains($0.key) }
    }
}

/// ドラッグしたものを落とす場所
enum PinnedDropTarget: Equatable {
    /// 行の前・後ろ（並べ替え）
    case before(PinnedKey)
    case after(PinnedKey)
    /// フォルダの中へ
    case into(String)
    /// 一覧の一番下へ（Item はフォルダから出す）
    case end
}

@MainActor
final class PinnedBrowser: ObservableObject {
    let model: AppModel

    @Published var query = ""
    /// 閉じているフォルダ。フォルダは開いた状態で並べる
    @Published private(set) var collapsed: Set<String> = []
    @Published var selection: Set<PinnedKey> = []
    /// ⇧ クリックで範囲を選ぶときの起点
    private var anchor: PinnedKey?
    /// 一覧をこの行までスクロールする
    @Published var revealed: PinnedKey?

    /// 名前を変えている行
    @Published var renaming: PinnedKey?
    @Published var renameText = ""

    /// 作ったばかりで、まだ Item の無いフォルダ。フォルダは Item が入っているときだけ存在するので、
    /// Item を入れるまではこの画面の中だけにある。
    @Published private(set) var pendingFolders: [String] = []

    /// 編集のシートを開いている Item
    @Published var editing: ClipItem?

    @Published var confirmingDelete = false
    private var deleting: [PinnedEntry] = []

    /// ドラッグしているもの。ほかのアプリから来たドラッグと見分けるため、運ぶ文字列に `dragToken` を入れる
    private(set) var dragging: [PinnedKey] = []
    private(set) var dragToken = ""
    @Published var dropIndicator: PinnedDropTarget?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Listing

    func listing() -> PinnedListing {
        let all = model.pinnedItems()
        let folders = shownFolders()
        let loose = all.filter { $0.folder == nil }
        if !query.isEmpty {
            let found = model.pinnedItems(query: query)
            return PinnedListing(searching: true, entries: found.map { .item($0, inFolder: false) },
                                 folders: folders, loose: loose)
        }
        var entries: [PinnedEntry] = []
        for folder in folders {
            let inside = all.filter { $0.folder == folder }
            let expanded = !collapsed.contains(folder)
            entries.append(.folder(name: folder, count: inside.count, expanded: expanded))
            if expanded { entries += inside.map { .item($0, inFolder: true) } }
        }
        entries += loose.map { .item($0, inFolder: false) }
        return PinnedListing(searching: false, entries: entries, folders: folders, loose: loose)
    }

    /// 一番上に並べるフォルダ。作ったばかりのフォルダは、並び順に入っていればその位置に、無ければ最後に出す
    private func shownFolders() -> [String] {
        let real = model.folders()
        let order = model.settings.folderOrder
        let extra = pendingFolders.filter { !real.contains($0) }
        let placed = order.filter { real.contains($0) || extra.contains($0) }
        return placed + real.filter { !placed.contains($0) } + extra.filter { !placed.contains($0) }
    }

    /// 履歴が変わったら、消えたフォルダや行を選択などから外す
    func tidy() {
        let real = model.folders()
        let pending = pendingFolders.filter { !real.contains($0) }
        if pending != pendingFolders { pendingFolders = pending }
        let present = Set(listing().entries.map(\.key))
        let kept = selection.intersection(present)
        if kept != selection { selection = kept }
        if let renaming, !present.contains(renaming) { self.renaming = nil }
    }

    /// その Item を選んで見せる（ポップアップの「設定で整理…」から）。フォルダの中なら開く
    func reveal(_ id: UUID?) {
        guard let id, let item = model.pinnedItems().first(where: { $0.id == id }) else { return }
        query = ""
        if let folder = item.folder { collapsed.remove(folder) }
        selection = [.item(id)]
        anchor = .item(id)
        revealed = .item(id)
    }

    // MARK: Open

    /// ダブルクリック・space。フォルダは開閉、Item は編集のシート
    func open(_ entry: PinnedEntry) {
        switch entry {
        case .folder(let name, _, _): toggle(name)
        case .item(let item, _):
            if renaming != nil { commitRename() }
            editing = item
        }
    }

    func toggle(_ folder: String) {
        setExpanded(folder, collapsed.contains(folder))
    }

    /// フォルダを開閉する。閉じるとき、中の Item を選んでいたら代わりにフォルダを選ぶ（Finder と同じ）
    func setExpanded(_ folder: String, _ expanded: Bool) {
        if expanded {
            collapsed.remove(folder)
            return
        }
        collapsed.insert(folder)
        let inside = Set(model.pinnedItems().filter { $0.folder == folder }.map { PinnedKey.item($0.id) })
        if !selection.isDisjoint(with: inside) {
            selection.subtract(inside)
            selection.insert(.folder(folder))
            anchor = .folder(folder)
        }
        if let renaming, inside.contains(renaming) { cancelRename() }
    }

    // MARK: Selection

    /// 行のクリック。⌘ で追加・解除、⇧ で起点からの範囲
    func click(_ key: PinnedKey, in listing: PinnedListing) {
        let flags = NSEvent.modifierFlags
        notice = nil
        if flags.contains(.command) {
            if selection.remove(key) == nil { selection.insert(key) }
            anchor = key
        } else if flags.contains(.shift), let anchor, let range = range(from: anchor, to: key, in: listing) {
            selection = range
        } else {
            selection = [key]
            anchor = key
        }
        if let renaming, renaming != key { commitRename() }
    }

    private func range(from start: PinnedKey, to end: PinnedKey, in listing: PinnedListing) -> Set<PinnedKey>? {
        let keys = listing.entries.map(\.key)
        guard let a = keys.firstIndex(of: start), let b = keys.firstIndex(of: end) else { return nil }
        return Set(keys[min(a, b)...max(a, b)])
    }

    /// ↑↓。⇧ で範囲を広げる
    func moveSelection(_ delta: Int, extend: Bool, in listing: PinnedListing) {
        let keys = listing.entries.map(\.key)
        guard !keys.isEmpty else { return }
        let indices = keys.indices.filter { selection.contains(keys[$0]) }
        let current = delta > 0 ? indices.max() : indices.min()
        let next = current.map { max(0, min(keys.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : keys.count - 1)
        if extend, let anchor, let range = range(from: anchor, to: keys[next], in: listing) {
            selection = range
        } else {
            selection = [keys[next]]
            anchor = keys[next]
        }
        revealed = keys[next]
    }

    /// 右クリックのメニューで操作する行。選んでいる行を右クリックしたら選んでいるすべて、ほかの行ならその行だけ（Finder と同じ）
    func targets(for entry: PinnedEntry, in listing: PinnedListing) -> [PinnedEntry] {
        selection.contains(entry.key) ? listing.entries(for: selection) : [entry]
    }

    // MARK: Keyboard

    func handleKey(_ press: KeyPress, listing: PinnedListing) -> Bool {
        guard renaming == nil, editing == nil else { return false }
        let command = press.modifiers.contains(.command)
        let selected = listing.entries(for: selection)
        switch press.key {
        case .downArrow where command:
            guard selected.count == 1 else { return false }
            open(selected[0])
        case .rightArrow:
            // 閉じたフォルダは開く
            let folders = selected.compactMap(\.key.folderName)
            guard !folders.isEmpty else { return false }
            for folder in folders { setExpanded(folder, true) }
        case .leftArrow:
            // 開いたフォルダは閉じ、フォルダの中の Item ではそのフォルダを選ぶ
            guard selected.count == 1 else { return false }
            switch selected[0] {
            case .folder(let name, _, let expanded):
                guard expanded else { return false }
                setExpanded(name, false)
            case .item(let item, let inFolder):
                guard inFolder, let folder = item.folder else { return false }
                selection = [.folder(folder)]
                anchor = .folder(folder)
                revealed = .folder(folder)
            }
        case .upArrow:
            moveSelection(-1, extend: press.modifiers.contains(.shift), in: listing)
        case .downArrow:
            moveSelection(1, extend: press.modifiers.contains(.shift), in: listing)
        case .return:
            // Finder と同じく ↩ で名前の変更
            guard selected.count == 1 else { return false }
            startRename(selected[0])
        case .space:
            guard selected.count == 1 else { return false }
            open(selected[0])
        case .delete, .deleteForward:
            guard !selected.isEmpty else { return false }
            requestDelete(selected)
        case .escape:
            if !selection.isEmpty { selection = [] } else if !query.isEmpty { query = "" } else { return false }
        default:
            if command, press.characters == "a" {
                selection = Set(listing.entries.map(\.key))
                return true
            }
            if command, press.characters == "c", selected.count == 1, let item = selected[0].item {
                copy(item)
                return true
            }
            return false
        }
        return true
    }

    // MARK: Rename

    func startRename(_ entry: PinnedEntry) {
        if renaming != nil { commitRename() }
        selection = [entry.key]
        anchor = entry.key
        switch entry {
        case .folder(let name, _, _): renameText = name
        case .item(let item, _): renameText = item.title ?? ""
        }
        renaming = entry.key
    }

    func cancelRename() {
        renaming = nil
    }

    func commitRename() {
        guard let key = renaming else { return }
        renaming = nil
        switch key {
        case .folder(let old):
            guard let name = PinFolders.normalizedFolder(renameText), name != old else { return }
            let renamed: String
            if let index = pendingFolders.firstIndex(of: old) {
                // まだ Item の無いフォルダは名前を差し替えるだけ。同じ名前のフォルダがあればそちらにまとめる
                pendingFolders.remove(at: index)
                renamed = PinFolders.existing(name, in: model.folders() + pendingFolders) ?? name
                if !model.folders().contains(renamed) && !pendingFolders.contains(renamed) { pendingFolders.append(renamed) }
                model.settings.folderOrder = PinFolders.renamed(model.settings.folderOrder, from: old, to: renamed)
            } else {
                model.renameFolder(old, to: name)
                renamed = PinFolders.existing(name, in: model.folders()) ?? name
            }
            if collapsed.remove(old) != nil { collapsed.insert(renamed) }
            selection = [.folder(renamed)]
            anchor = .folder(renamed)
        case .item(let id):
            guard let item = model.pinnedItems().first(where: { $0.id == id }),
                  PinFolders.normalizedTitle(renameText) != item.title else { return }
            // 空にすると別名を外し、本文を名前として出す
            model.setTitle(item, renameText)
        }
    }

    // MARK: Folders

    /// 新しいフォルダ。Item を選んでいれば、それを入れたフォルダを作る（Finder の「選択項目から新規フォルダ」）。
    /// 作ったらすぐ名前を入力できるようにする。
    func newFolder(in listing: PinnedListing) {
        guard !listing.searching else { return }
        if renaming != nil { commitRename() }
        var name = String(localized: "新しいフォルダ")
        var number = 2
        while PinFolders.existing(name, in: listing.folders) != nil {
            name = String(localized: "新しいフォルダ \(number)")
            number += 1
        }
        let items = listing.entries(for: selection).compactMap(\.item)
        if items.isEmpty {
            pendingFolders.append(name)
        } else {
            model.setFolder(items, name)
        }
        // 新しいフォルダは一番下のフォルダの後ろに置く
        model.settings.folderOrder = listing.folders.filter { $0 != name } + [name]
        startRename(.folder(name: name, count: items.count, expanded: true))
        revealed = .folder(name)
    }

    // MARK: Items

    /// 操作できなかった理由（下の帯に出す）
    @Published var notice: String?

    func copy(_ item: ClipItem) {
        notice = model.writeItemToPasteboard(item) ? nil : String(localized: "ファイルが見つからないため、コピーできませんでした。")
    }

    func move(_ items: [ClipItem], to folder: String?) {
        model.setFolder(items, folder)
        selection.subtract(items.map { .item($0.id) })
    }

    func unpin(_ items: [ClipItem]) {
        for item in items { model.togglePin(item) }
        selection.subtract(items.map { .item($0.id) })
    }

    // MARK: Delete

    func requestDelete(_ entries: [PinnedEntry]) {
        guard !entries.isEmpty else { return }
        deleting = entries
        confirmingDelete = true
    }

    var deleteTitle: String {
        if deleting.count == 1, case .folder(let name, _, _) = deleting[0] {
            return String(localized: "フォルダ「\(name)」を削除しますか？")
        }
        if deleting.count == 1 { return String(localized: "この Item を削除しますか？") }
        return String(localized: "\(deleting.count) 項目を削除しますか？")
    }

    var deleteMessage: String {
        let folders = deleting.filter { $0.key.folderName != nil }
        let items = deleting.count - folders.count
        if items == 0 {
            return String(localized: "中の Item はピン留めのまま、フォルダの外に移ります。")
        }
        if folders.isEmpty {
            return String(localized: "履歴からも消えます。元に戻せません。")
        }
        return String(localized: "Item は履歴からも消えます。フォルダの中の Item はピン留めのまま、フォルダの外に移ります。")
    }

    func performDelete() {
        for entry in deleting {
            switch entry {
            case .folder(let name, _, _):
                if let index = pendingFolders.firstIndex(of: name) {
                    pendingFolders.remove(at: index)
                    model.settings.folderOrder.removeAll { $0 == name }
                } else {
                    model.removeFolder(name)
                }
                collapsed.remove(name)
            case .item(let item, _):
                model.delete(item)
            }
        }
        selection.subtract(deleting.map(\.key))
        deleting = []
    }

    // MARK: Drag and drop

    /// 行をドラッグし始めた。選んでいる行をドラッグしたら、選んでいるうち同じ種類（Item かフォルダ）のものすべてを運ぶ
    func beginDrag(_ entry: PinnedEntry, in listing: PinnedListing) -> NSItemProvider {
        if renaming != nil { commitRename() }
        let isFolder = entry.key.folderName != nil
        if selection.contains(entry.key) {
            dragging = listing.entries(for: selection).map(\.key).filter { ($0.folderName != nil) == isFolder }
        } else {
            selection = [entry.key]
            anchor = entry.key
            dragging = [entry.key]
        }
        dragToken = "clingcling-pinned:" + UUID().uuidString
        return NSItemProvider(object: dragToken as NSString)
    }

    var draggingCount: Int { dragging.count }

    /// ドラッグを載せている場所。落とせない場所なら nil
    func proposal(for target: PinnedDropTarget, at y: CGFloat, height: CGFloat, in listing: PinnedListing) -> PinnedDropTarget? {
        guard !dragging.isEmpty else { return nil }
        let folders = dragging.compactMap(\.folderName)
        let items = dragging.compactMap(\.itemID)
        let upper = y < height / 2
        switch target {
        case .before(let key), .after(let key):
            if let name = key.folderName {
                // Item はフォルダの中へ、フォルダはその前後へ（開いたフォルダの下は中の行なので前だけ）
                if !items.isEmpty { return .into(name) }
                guard !folders.contains(name) else { return nil }
                let expanded = !collapsed.contains(name)
                return upper || expanded ? .before(key) : .after(key)
            }
            guard !listing.searching, let id = key.itemID else { return nil }
            if !folders.isEmpty {
                // フォルダは、フォルダの外の先頭の Item の前（フォルダの並びの最後）にだけ落とせる
                return listing.loose.first?.id == id ? .before(key) : nil
            }
            guard !items.contains(id) else { return nil }
            return upper ? .before(key) : .after(key)
        case .end:
            return listing.searching ? nil : .end
        case .into(let name):
            return items.isEmpty ? nil : .into(name)
        }
    }

    /// 落とした。運んでいる文字列が自分のドラッグのものか確かめてから動かす
    func drop(_ providers: [NSItemProvider], listing: PinnedListing) -> Bool {
        guard let target = dropIndicator, let provider = providers.first else {
            dropIndicator = nil
            return false
        }
        let token = dragToken
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            let text = (object as? NSString).map(String.init)
            Task { @MainActor [weak self] in
                guard let self, text == token else { return }
                self.perform(target, listing: listing)
            }
        }
        dropIndicator = nil
        return true
    }

    private func perform(_ target: PinnedDropTarget, listing: PinnedListing) {
        let all = model.pinnedItems()
        let items = dragging.compactMap { key in all.first { $0.id == key.itemID } }
        let folders = dragging.compactMap(\.folderName)
        dragging = []
        if !folders.isEmpty {
            let shown = listing.folders
            switch target {
            case .before(let key), .after(let key):
                guard let name = key.folderName, let index = shown.firstIndex(of: name) else {
                    // フォルダの外の Item の前 = フォルダの並びの最後
                    model.moveFolders(folders, in: shown, before: nil)
                    return
                }
                let next = target == .after(key) ? shown[(index + 1)...].first { !folders.contains($0) } : name
                model.moveFolders(folders, in: shown, before: next)
            case .end:
                model.moveFolders(folders, in: shown, before: nil)
            case .into:
                break
            }
            return
        }
        switch target {
        case .into(let name):
            move(items, to: name)
            selection = Set(items.map { .item($0.id) })
        case .end:
            place(items, in: nil, before: nil)
        case .before(let key), .after(let key):
            guard let row = all.first(where: { $0.id == key.itemID }) else { return }
            // 落とした行と同じ場所（フォルダの中か外）へ入れてから、その行の前後に並べる
            place(items, in: row.folder, before: row, after: target == .after(key))
        }
    }

    /// `items` をフォルダ `folder`（nil ならフォルダの外）へ入れ、`target` の前（`after` なら後ろ、nil なら最後）に並べる
    private func place(_ items: [ClipItem], in folder: String?, before target: ClipItem?, after: Bool = false) {
        let changing = items.filter { $0.folder != folder }
        if !changing.isEmpty { model.setFolder(changing, folder) }
        let fresh = model.pinnedItems()
        let moving = Set(items.map(\.id))
        let visible = fresh.filter { $0.folder == folder }
        var next: ClipItem?
        if let target, let index = visible.firstIndex(where: { $0.id == target.id }) {
            next = after ? visible[(index + 1)...].first { !moving.contains($0.id) } : visible[index]
        }
        model.movePinned(fresh.filter { moving.contains($0.id) }, visible: visible, before: next)
        selection = Set(items.map { .item($0.id) })
    }
}

// MARK: - Toolbar

private struct PinnedToolbar: View {
    @ObservedObject var browser: PinnedBrowser
    let listing: PinnedListing

    var body: some View {
        HStack(spacing: 8) {
            Button {
                browser.newFolder(in: listing)
            } label: {
                Label("新しいフォルダ", systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(listing.searching)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("新しいフォルダ（⇧⌘N）。Item を選んでいれば、それを入れたフォルダを作ります")

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("検索", text: $browser.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !browser.query.isEmpty {
                    Button {
                        browser.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("検索をクリア")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 170, height: 24)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

// MARK: - List

private enum PinnedColumns {
    static let kind: CGFloat = 96
    static let detail: CGFloat = 104
    static let rowHeight: CGFloat = 28
    /// 左端の開閉の三角の幅
    static let disclosure: CGFloat = 14
    /// フォルダの中の行を下げる幅
    static let indent: CGFloat = 20
}

private struct ColumnHeader: View {
    let searching: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("名前")
                .padding(.leading, PinnedColumns.disclosure + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("種類").frame(width: PinnedColumns.kind, alignment: .leading)
            Text(searching ? "場所" : "コピー元").frame(width: PinnedColumns.detail, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 24)
    }
}

/// `@State` を使わずにホバーを持つための入れ物
@MainActor
private final class RowHover: ObservableObject {
    @Published var isHovered = false
}

private struct EntryRow: View {
    @ObservedObject var browser: PinnedBrowser
    let entry: PinnedEntry
    let listing: PinnedListing
    /// 一覧にキーボードのフォーカスがある（選択の色を濃くする）
    let listFocused: Bool
    let focusList: () -> Void
    @StateObject private var hover = RowHover()

    private var isSelected: Bool { browser.selection.contains(entry.key) }
    /// 選択中で、一覧が前面（白い文字をアクセントの面に載せる）
    private var isEmphasized: Bool { isSelected && listFocused && browser.renaming != entry.key }
    private var isDropInto: Bool {
        if case .into(let name) = browser.dropIndicator, entry.key == .folder(name) { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                disclosure
                HStack(spacing: 8) {
                    EntryIcon(entry: entry, model: browser.model, emphasized: isEmphasized)
                    name
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: kind)
                .frame(width: PinnedColumns.kind, alignment: .leading)
                .foregroundStyle(secondaryStyle)
            Text(verbatim: detail)
                .frame(width: PinnedColumns.detail, alignment: .leading)
                .foregroundStyle(secondaryStyle)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 10)
        .frame(height: PinnedColumns.rowHeight)
        .foregroundStyle(isEmphasized ? Color.white : Color.primary)
        .background(background)
        .overlay(alignment: .top) {
            if browser.dropIndicator == .before(entry.key) { InsertionLine().offset(y: -1) }
        }
        .overlay(alignment: .bottom) {
            if browser.dropIndicator == .after(entry.key) { InsertionLine().offset(y: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hover.isHovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { browser.open(entry) })
        .simultaneousGesture(TapGesture().onEnded {
            browser.click(entry.key, in: listing)
            focusList()
        })
        .onDrag {
            browser.beginDrag(entry, in: listing)
        } preview: {
            DragPreview(entry: entry, count: browser.draggingCount, model: browser.model)
        }
        .onDrop(of: [.utf8PlainText], delegate: PinnedDrop(browser: browser, target: .before(entry.key), listing: listing))
        .contextMenu { EntryMenu(browser: browser, entry: entry, listing: listing) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// フォルダの開閉の三角。フォルダの中の行は、その分だけ左を下げる
    @ViewBuilder
    private var disclosure: some View {
        switch entry {
        case .folder(let name, _, let expanded):
            Button {
                browser.toggle(name)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: PinnedColumns.disclosure, height: PinnedColumns.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryStyle)
            .accessibilityLabel(expanded ? "フォルダを閉じる" : "フォルダを開く")
        case .item(_, let inFolder):
            Color.clear.frame(width: PinnedColumns.disclosure + (inFolder ? PinnedColumns.indent : 0), height: 1)
        }
    }

    @ViewBuilder
    private var name: some View {
        if browser.renaming == entry.key {
            RenameField(browser: browser, placeholder: entry.item.map(Presentation.preview) ?? "")
        } else {
            switch entry {
            case .folder(let name, _, _):
                Text(verbatim: name).fontWeight(.medium)
            case .item(let item, _):
                if let title = item.title {
                    Text(verbatim: title).fontWeight(.medium)
                        + Text(verbatim: "  " + Presentation.preview(item)).foregroundStyle(secondaryStyle)
                } else {
                    Text(verbatim: Presentation.preview(item))
                        .font(.system(size: 13, design: Presentation.isMonospaced(item.contentType) ? .monospaced : .default))
                }
            }
        }
    }

    private var kind: String {
        switch entry {
        case .folder: String(localized: "フォルダ")
        case .item(let item, _): Presentation.kindName(item)
        }
    }

    private var detail: String {
        switch entry {
        case .folder(_, let count, _): String(localized: "\(count) 項目")
        case .item(let item, _):
            listing.searching ? (item.folder ?? "—") : (item.source.name ?? "—")
        }
    }

    private var secondaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack {
            if isDropInto {
                shape.fill(Theme.hover).overlay(shape.strokeBorder(Theme.tint, lineWidth: 1.5))
            } else if isEmphasized {
                shape.fill(Theme.accent)
            } else if isSelected {
                shape.fill(Theme.selection).overlay(shape.strokeBorder(Theme.rim, lineWidth: 0.5))
            } else if hover.isHovered {
                shape.fill(Theme.hover)
            }
        }
    }
}

private struct EntryIcon: View {
    let entry: PinnedEntry
    let model: AppModel
    let emphasized: Bool

    var body: some View {
        Group {
            switch entry {
            case .folder:
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            case .item(let item, _):
                if let thumbnail = model.thumbnail(for: item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else if let icon = model.fileIcon(for: item) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: Presentation.rowIcon(for: item))
                        .font(.system(size: 12))
                        .foregroundStyle(emphasized ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                }
            }
        }
        .frame(width: 20)
    }
}

/// 名前の入力欄（↩ で確定、esc で取り消し、ほかをクリックしても確定）
private struct RenameField: View {
    @ObservedObject var browser: PinnedBrowser
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(text: $browser.renameText, prompt: Text(verbatim: placeholder)) { EmptyView() }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit { browser.commitRename() }
            .onExitCommand { browser.cancelRename() }
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { browser.commitRename() }
            }
    }
}

/// ドラッグしているものの見た目
private struct DragPreview: View {
    let entry: PinnedEntry
    let count: Int
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            EntryIcon(entry: entry, model: model, emphasized: false)
            switch entry {
            case .folder(let name, _, _): Text(verbatim: name)
            case .item(let item, _): Text(verbatim: item.title ?? Presentation.preview(item))
            }
            if count > 1 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(maxWidth: 260, minHeight: 26)
    }
}

/// ドラッグで並べ替えるときに、入る位置に出す線
private struct InsertionLine: View {
    var body: some View {
        Capsule()
            .fill(Theme.tint)
            .frame(height: 2)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
    }
}

/// 行・パス・一覧の下の余白に落としたとき
private struct PinnedDrop: DropDelegate {
    let browser: PinnedBrowser
    let target: PinnedDropTarget
    let listing: PinnedListing

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { browser.draggingCount > 0 }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            let proposal = browser.proposal(for: target, at: info.location.y, height: PinnedColumns.rowHeight, in: listing)
            if browser.dropIndicator != proposal { browser.dropIndicator = proposal }
            return DropProposal(operation: proposal == nil ? .forbidden : .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            browser.dropIndicator = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            browser.drop(info.itemProviders(for: [.utf8PlainText]), listing: listing)
        }
    }
}

// MARK: - Menus

/// 行の右クリック。選んでいる行なら選んでいるすべてに、ほかの行ならその行だけに効く
private struct EntryMenu: View {
    @ObservedObject var browser: PinnedBrowser
    let entry: PinnedEntry
    let listing: PinnedListing

    var body: some View {
        let targets = browser.targets(for: entry, in: listing)
        let items = targets.compactMap(\.item)
        let folders = targets.compactMap(\.key.folderName)
        if targets.count == 1 {
            if case .folder(_, _, let expanded) = entry {
                Button(expanded ? "閉じる" : "開く") { browser.open(entry) }
            } else {
                Button("編集…") { browser.open(entry) }
            }
            Button("名前を変更") { browser.startRename(entry) }
            if let item = entry.item {
                Button("コピー") { browser.copy(item) }
            }
            Divider()
        }
        if !items.isEmpty, folders.isEmpty {
            Menu("フォルダへ移動") {
                Button("フォルダの外") { browser.move(items, to: nil) }
                    .disabled(items.allSatisfy { $0.folder == nil })
                if !listing.folders.isEmpty { Divider() }
                ForEach(listing.folders, id: \.self) { folder in
                    Button(folder) { browser.move(items, to: folder) }
                        .disabled(items.allSatisfy { $0.folder == folder })
                }
            }
            if !listing.searching {
                Button("選択項目から新しいフォルダ") {
                    browser.selection = Set(items.map { .item($0.id) })
                    browser.newFolder(in: listing)
                }
            }
            Button("ピン留めを外す") { browser.unpin(items) }
            Divider()
        }
        Button(items.isEmpty ? "フォルダを削除…" : "削除…", role: .destructive) {
            browser.requestDelete(targets)
        }
    }
}

/// 一覧の余白の右クリック
private struct BackgroundMenu: View {
    @ObservedObject var browser: PinnedBrowser
    let listing: PinnedListing

    var body: some View {
        Button("新しいフォルダ") {
            browser.selection = []
            browser.newFolder(in: listing)
        }
        .disabled(listing.searching)
    }
}

// MARK: - Empty and status

private struct EmptyMessage: View {
    let listing: PinnedListing

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .allowsHitTesting(false)
    }

    private var message: LocalizedStringKey {
        if listing.searching { return "一致するピン留めはありません。" }
        return "ピン留めした Item はまだありません。ポップアップのアクションメニューか ⌘P でピン留めできます。"
    }
}

private struct StatusBar: View {
    @ObservedObject var browser: PinnedBrowser
    let listing: PinnedListing

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: summary)
            Spacer(minLength: 8)
            if let notice = browser.notice {
                Text(verbatim: notice)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text("ダブルクリックで編集・ドラッグで移動と並べ替え・↩ で名前を変更")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private var summary: String {
        let selected = listing.entries(for: browser.selection).count
        let total = listing.entries.count
        if selected > 0 { return String(localized: "\(total) 項目中 \(selected) 項目を選択") }
        return String(localized: "\(total) 項目")
    }
}

// MARK: - Editor

/// Item を開いたときの編集のシート。別名と本文を変える
private struct ItemEditor: View {
    let item: ClipItem
    let model: AppModel
    let close: () -> Void
    @StateObject private var draft: EditorDraft

    init(item: ClipItem, model: AppModel, close: @escaping () -> Void) {
        self.item = item
        self.model = model
        self.close = close
        _draft = StateObject(wrappedValue: EditorDraft(item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                EntryIcon(entry: .item(item, inFolder: false), model: model, emphasized: false)
                Text(verbatim: item.title ?? Presentation.preview(item))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("名前").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("名前", text: $draft.title, prompt: Text("名前を付けると、一覧には本文の代わりに出ます"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("内容").font(.system(size: 12)).foregroundStyle(.secondary)
                content
            }
            Text(verbatim: info)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let message = draft.message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("コピー") {
                    draft.message = model.writeItemToPasteboard(item)
                        ? nil : String(localized: "ファイルが見つからないため、コピーできませんでした。")
                }
                Spacer()
                Button("キャンセル", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if item.isContentEditable {
            TextEditor(text: $draft.content)
                .font(.system(size: 12, design: Presentation.isMonospaced(item.contentType) ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 180)
                .background(Theme.hover, in: shape)
                .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
            Text("書き換えると、コピーしたときと同じく、種類と Mac の外に出してよいかを判定し直します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                Text(verbatim: item.fullText(limit: 4_000, detector: SecretDetector()))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 120)
            .background(Theme.hover, in: shape)
            Text(readOnlyReason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readOnlyReason: LocalizedStringKey {
        if item.isImage { return "画像の内容は書き換えられません。" }
        if item.isFile { return "ファイルの内容は書き換えられません。" }
        return "伏せて表示している内容は書き換えられません。"
    }

    private var info: String {
        [Presentation.kindName(item), item.folder ?? String(localized: "ピン留め"), Presentation.meta(item)]
            .joined(separator: " · ")
    }

    private func save() {
        draft.message = nil
        if item.isContentEditable, draft.content != item.content,
           let reason = model.updateContent(item, to: draft.content) {
            draft.message = reason
            return
        }
        if PinFolders.normalizedTitle(draft.title) != item.title { model.setTitle(item, draft.title) }
        close()
    }
}

@MainActor
private final class EditorDraft: ObservableObject {
    @Published var title: String
    @Published var content: String
    @Published var message: String?

    init(_ item: ClipItem) {
        title = item.title ?? ""
        content = item.content
    }
}
