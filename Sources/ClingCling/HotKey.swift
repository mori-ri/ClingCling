import AppKit
import Carbon.HIToolbox
import ClingClingCore

/// グローバルショートカット。Carbon の RegisterEventHotKey はアクセシビリティ権限が不要。
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var current: Shortcut?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// `shortcut` に切り替える。登録できなければ元のショートカットのまま false を返す。
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        guard install(shortcut) else {
            if let current { _ = install(current) }
            return false
        }
        current = shortcut
        return true
    }

    /// 新しいショートカットを記録している間は、今のショートカットが反応しないよう外しておく
    func suspend() {
        unregister()
    }

    func resume() {
        if hotKeyRef == nil, let current { _ = install(current) }
    }

    private func install(_ shortcut: Shortcut) -> Bool {
        let id = EventHotKeyID(signature: OSType(0x4350_4355), id: 1) // "CPCU"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("ClingCling: failed to register hot key (\(status))")
            hotKeyRef = nil
        }
        return status == noErr
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

extension Shortcut {
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }
}
