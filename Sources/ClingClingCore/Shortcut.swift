import Foundation

/// ポップアップを開くグローバルショートカット。`keyCode` は macOS の仮想キーコード（キーの物理的な位置）。
public struct Shortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// 設定できない理由
    public enum Problem: Equatable, Sendable {
        /// ⌘ ⌃ ⌥ のどれも含まない
        case needsModifier
        /// ⌘ か ⌥ だけの組み合わせ。アプリの操作や文字の入力を奪ってしまう
        case conflictsWithApps
        /// 表示できないキー
        case unsupportedKey
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private static let v: UInt16 = 9

    public static let `default` = Shortcut(keyCode: v, modifiers: [.command, .shift])
    public static let presets = [
        Shortcut.default,
        Shortcut(keyCode: v, modifiers: [.control, .command]),
        Shortcut(keyCode: v, modifiers: [.control, .option]),
        Shortcut(keyCode: v, modifiers: [.control, .shift]),
    ]

    /// 例: ⇧⌘V。macOS のメニューと同じ ⌃⌥⇧⌘ の順に並べる。
    public var displayName: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + (Self.keyNames[keyCode] ?? "Key\(keyCode)")
    }

    public var problem: Problem? {
        guard Self.keyNames[keyCode] != nil else { return .unsupportedKey }
        if Self.functionKeys.contains(keyCode) { return nil }
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else { return .needsModifier }
        return modifiers == [.command] || modifiers == [.option] ? .conflictsWithApps : nil
    }

    /// メニューの項目に添える文字。1 文字で表せるキーだけ。
    public var keyEquivalent: String? {
        guard let name = Self.keyNames[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }

    private static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// US 配列での名前（JIS 配列だけにあるキーを含む）
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 93: "¥", 94: "_", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘",
        121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]
}
