import AppKit
import Carbon.HIToolbox

/// A dictation shortcut: either a key with modifiers, or a single modifier key held on its own.
public nonisolated struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    /// Raw `NSEvent.ModifierFlags`, masked to command/option/control/shift.
    public var modifiers: UInt
    public var isModifierOnly: Bool
    /// A modifier tapped twice in quick succession (either side). Starts and stops a take; there is nothing to hold.
    public var isDoubleTap: Bool

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isModifierOnly: Bool = false, isDoubleTap: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Shortcut.relevant).rawValue
        self.isModifierOnly = isModifierOnly || isDoubleTap
        self.isDoubleTap = isDoubleTap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt.self, forKey: .modifiers)
        isModifierOnly = try container.decode(Bool.self, forKey: .isModifierOnly)
        // Added later; shortcuts saved before it existed are not double-taps.
        isDoubleTap = try container.decodeIfPresent(Bool.self, forKey: .isDoubleTap) ?? false
    }

    public static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    public static let optionSpace = Shortcut(keyCode: UInt16(kVK_Space), modifiers: .option)
    /// The default: tap Option twice.
    public static let doubleTapOption = Shortcut(keyCode: UInt16(kVK_Option), modifiers: [], isDoubleTap: true)

    public var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Keycap labels in the order macOS writes them: ⌃ ⌥ ⇧ ⌘ then the key.
    public var keycaps: [String] {
        if isDoubleTap { return [(Shortcut.modifierSymbols[keyCode] ?? "Key \(keyCode)") + " ×2"] }
        if isModifierOnly { return [Shortcut.modifierKeyNames[keyCode] ?? "Key \(keyCode)"] }
        var caps: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { caps.append("⌃") }
        if flags.contains(.option) { caps.append("⌥") }
        if flags.contains(.shift) { caps.append("⇧") }
        if flags.contains(.command) { caps.append("⌘") }
        caps.append(Shortcut.keyNames[keyCode] ?? Shortcut.character(for: keyCode) ?? "Key \(keyCode)")
        return caps
    }

    public var spokenName: String {
        isDoubleTap ? "double-tap \(Shortcut.modifierSymbols[keyCode] ?? "the key")" : keycaps.joined(separator: " ")
    }

    /// A shortcut macOS already uses, with what it does. Nil when it is free as far as we know.
    public var systemConflict: String? {
        guard !isModifierOnly, keyCode == UInt16(kVK_Space) else { return nil }
        let flags = modifierFlags
        if flags == .command { return "open Spotlight" }
        if flags == .control { return "select the previous input source" }
        if flags == [.control, .option] { return "select the next input source" }
        if flags == [.command, .option] { return "open a Finder search window" }
        if flags == [.control, .command] { return "show the emoji picker" }
        return nil
    }

    /// Either-side symbols, for double-tap shortcuts.
    static let modifierSymbols: [UInt16: String] = [54: "⌘", 55: "⌘", 56: "⇧", 60: "⇧", 58: "⌥", 61: "⌥", 59: "⌃", 62: "⌃", 63: "fn"]

    static let modifierKeyNames: [UInt16: String] = [
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥", 59: "Left ⌃", 62: "Right ⌃", 63: "fn",
    ]

    static let keyNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Escape): "esc",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    /// The character the key produces in the current keyboard layout, uppercased.
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(raw, to: CFData.self) as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
