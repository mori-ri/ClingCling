import AppKit
import ApplicationServices
import ClingClingCore

/// Smart Action のうちローカルで完結するものを実行する
@MainActor
enum ActionExecutor {
    enum Outcome {
        /// 実行完了。ポップアップを閉じる（`paste` なら直前のアプリへ貼り付け）
        case close(paste: Bool)
        /// ポップアップ内に結果を表示する
        case show(title: String, text: String)
        case failure(String)
    }

    static func perform(_ action: SmartAction, on item: ClipItem, model: AppModel) -> Outcome {
        let text = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .copy:
            model.writeItemToPasteboard(item)
            return .close(paste: model.settings.pasteAfterCopy)

        case .saveImage:
            return saveImage(item, model: model)

        case .open:
            guard let url = normalizedURL(text) else { return .failure(String(localized: "URL を開けませんでした。")) }
            NSWorkspace.shared.open(url)
            return .close(paste: false)

        case .markdown:
            guard let url = normalizedURL(text) else { return .failure(String(localized: "URL を解析できませんでした。")) }
            model.writeToPasteboard("[\(markdownTitle(for: url))](\(url.absoluteString))")
            return .close(paste: model.settings.pasteAfterCopy)

        case .search:
            let query = String(text.split(whereSeparator: \.isNewline).first ?? "").prefix(200)
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: String(query))]
            NSWorkspace.shared.open(components.url!)
            return .close(paste: false)

        case .newMail:
            guard let url = URL(string: "mailto:\(text)") else { return .failure(String(localized: "メールを作成できませんでした。")) }
            NSWorkspace.shared.open(url)
            return .close(paste: false)

        case .openMaps:
            var components = URLComponents(string: "maps://")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            NSWorkspace.shared.open(components.url!)
            return .close(paste: false)

        case .format:
            guard let pretty = prettyJSON(text) else { return .failure(String(localized: "JSON として解析できませんでした。")) }
            model.writeToPasteboard(pretty)
            return .show(title: String(localized: "Formatted JSON（コピー済み）"), text: pretty)

        case .inspect:
            guard let summary = inspectJSON(text) else { return .failure(String(localized: "JSON として解析できませんでした。")) }
            return .show(title: "JSON Inspect", text: summary)

        case .run:
            return runInTerminal(text)

        case .explain, .polish, .shorten, .translate:
            // AI への受け渡しは PopupViewModel 側で確認 UI を挟んでから AIHandoff で行う
            return .failure("AI action")
        }
    }

    // MARK: - Paste

    /// 直前のアプリへ ⌘V を送る。アクセシビリティ権限が必要。
    static func pasteIntoFrontmostApp() {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postKey(0x09, flags: .maskCommand)
        }
    }

    /// 前面のアプリへキー入力を送る。アクセシビリティ権限が必要。
    static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// アクセシビリティ権限のダイアログを出す（Paste after Copy を有効にしたとき）
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定のアクセシビリティの一覧を開く。
    /// 一度も問い合わせていないアプリは一覧に載らないので、先に問い合わせる。
    static func openAccessibilitySettings() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    static func normalizedURL(_ text: String) -> URL? {
        let candidate = text.lowercased().hasPrefix("www.") ? "https://" + text : text
        return URL(string: candidate)
    }

    /// ページタイトルは取得しない（ネットワークアクセスを避ける）。URL から読みやすいラベルを作る。
    static func markdownTitle(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "github.com", parts.count >= 2 {
            return "GitHub - " + parts.prefix(2).joined(separator: "/")
        }
        guard let last = parts.last else { return host }
        let label = last.removingPercentEncoding?.replacingOccurrences(of: "-", with: " ") ?? last
        return "\(host) - \(label)"
    }

    static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// JSON の構造をローカルで要約する（キー・型・件数）
    static func inspectJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var lines: [String] = []
        func describe(_ value: Any, path: String, depth: Int) {
            guard depth < 4, lines.count < 200 else { return }
            let indent = String(repeating: "  ", count: depth)
            switch value {
            case let dict as [String: Any]:
                lines.append("\(indent)\(path): object (\(dict.count) keys)")
                for key in dict.keys.sorted() { describe(dict[key]!, path: key, depth: depth + 1) }
            case let array as [Any]:
                lines.append("\(indent)\(path): array (\(array.count) items)")
                if let first = array.first { describe(first, path: "[0]", depth: depth + 1) }
            case is NSNull:
                lines.append("\(indent)\(path): null")
            case let number as NSNumber:
                let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                lines.append("\(indent)\(path): \(isBool ? "bool" : "number") = \(number)")
            case let string as String:
                lines.append("\(indent)\(path): string = \"\(string.prefix(60))\(string.count > 60 ? "…" : "")\"")
            default:
                lines.append("\(indent)\(path): \(type(of: value))")
            }
        }
        describe(object, path: "$", depth: 0)
        return lines.joined(separator: "\n")
    }

    /// 画像を「ダウンロード」に PNG で書き出して Finder で示す
    private static func saveImage(_ item: ClipItem, model: AppModel) -> Outcome {
        guard let data = model.imageData(for: item) else { return .failure(String(localized: "画像が見つかりませんでした。")) }
        return saveToDownloads(data, item: item)
    }

    /// Item を「ダウンロード」にファイルで書き出して Finder で示す。
    /// テキストは UTF-8 の `.txt`（JSON は `.json`）、画像は PNG。
    static func saveFile(_ item: ClipItem, model: AppModel) -> Outcome {
        // 一時 Item（Secret・認証コード）はディスクに書かない約束なので、ファイルにも書かない
        guard ExportFile.canExport(item) else {
            return .failure(String(localized: "Sensitive な一時 Item はファイルに保存できません。"))
        }
        if item.isImage { return saveImage(item, model: model) }
        guard let data = ExportFile.textData(for: item) else { return .failure(String(localized: "保存できませんでした。")) }
        return saveToDownloads(data, item: item)
    }

    private static func saveToDownloads(_ data: Data, item: ClipItem) -> Outcome {
        let fm = FileManager.default
        guard let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return .failure(String(localized: "保存できませんでした。"))
        }
        let url = ExportFile.uniqueURL(in: folder,
                                       baseName: ExportFile.baseName(for: item.lastCopiedAt),
                                       fileExtension: ExportFile.fileExtension(for: item))
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            return .failure(String(localized: "保存できませんでした: \(error.localizedDescription)"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .close(paste: false)
    }

    private static func runInTerminal(_ command: String) -> Outcome {
        var cmd = command
        for prompt in ["$ ", "% "] where cmd.hasPrefix(prompt) { cmd = String(cmd.dropFirst(prompt.count)) }
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return .failure(String(localized: "Terminal で実行できませんでした: \(error[NSAppleScript.errorMessage] ?? "")"))
        }
        return .close(paste: false)
    }
}
