import Foundation
import Testing
@testable import ClingClingCore

struct ShortcutTests {
    private let a: UInt16 = 0
    private let f5: UInt16 = 96

    @Test func defaultIsCommandShiftV() {
        #expect(Shortcut.default.displayName == "⇧⌘V")
        #expect(Shortcut.default.problem == nil)
    }

    @Test func allPresetsAreUsable() {
        #expect(Set(Shortcut.presets).count == Shortcut.presets.count)
        #expect(Shortcut.presets.allSatisfy { $0.problem == nil })
    }

    @Test func showsModifiersInMenuOrder() {
        let shortcut = Shortcut(keyCode: a, modifiers: [.command, .shift, .option, .control])
        #expect(shortcut.displayName == "⌃⌥⇧⌘A")
    }

    @Test func requiresCommandControlOrOption() {
        #expect(Shortcut(keyCode: a, modifiers: []).problem == .needsModifier)
        #expect(Shortcut(keyCode: a, modifiers: [.shift]).problem == .needsModifier)
        #expect(Shortcut(keyCode: a, modifiers: [.control]).problem == nil)
    }

    @Test func rejectsCombinationsAppsAndTypingUse() {
        #expect(Shortcut(keyCode: a, modifiers: [.command]).problem == .conflictsWithApps)
        #expect(Shortcut(keyCode: a, modifiers: [.option]).problem == .conflictsWithApps)
        #expect(Shortcut(keyCode: a, modifiers: [.option, .shift]).problem == nil)
    }

    @Test func functionKeysWorkAlone() {
        #expect(Shortcut(keyCode: f5, modifiers: []).problem == nil)
        #expect(Shortcut(keyCode: f5, modifiers: [.command]).problem == nil)
    }

    @Test func rejectsKeysItCannotName() {
        #expect(Shortcut(keyCode: 200, modifiers: [.command, .shift]).problem == .unsupportedKey)
    }

    @Test func keyEquivalentCoversSingleCharacterKeysOnly() {
        #expect(Shortcut.default.keyEquivalent == "v")
        #expect(Shortcut(keyCode: f5, modifiers: []).keyEquivalent == nil)
    }

    @Test func survivesSavingAndLoading() throws {
        let original = Shortcut(keyCode: 12, modifiers: [.control, .option])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == original)
    }
}
