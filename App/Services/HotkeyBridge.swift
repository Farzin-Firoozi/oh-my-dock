import Carbon.HIToolbox
import KeyboardShortcuts
import OhMyDockCore

/// Converts between profile JSON hotkeys and KeyboardShortcuts' carbon-based shortcuts.
enum HotkeyBridge {
    static func shortcut(from hotkey: Hotkey?) -> KeyboardShortcuts.Shortcut? {
        guard let hotkey else { return nil }
        return KeyboardShortcuts.Shortcut(
            carbonKeyCode: Int(hotkey.keyCode),
            carbonModifiers: carbonModifiers(from: hotkey.modifiers)
        )
    }

    static func hotkey(from shortcut: KeyboardShortcuts.Shortcut?) -> Hotkey? {
        guard let shortcut else { return nil }
        return Hotkey(
            keyCode: UInt16(shortcut.carbonKeyCode),
            modifiers: modifiers(from: shortcut.carbonModifiers)
        )
    }

    private static func carbonModifiers(from modifiers: Hotkey.Modifiers) -> Int {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return flags
    }

    private static func modifiers(from carbon: Int) -> Hotkey.Modifiers {
        var modifiers = Hotkey.Modifiers()
        if carbon & cmdKey != 0 { modifiers.insert(.command) }
        if carbon & optionKey != 0 { modifiers.insert(.option) }
        if carbon & controlKey != 0 { modifiers.insert(.control) }
        if carbon & shiftKey != 0 { modifiers.insert(.shift) }
        return modifiers
    }
}
