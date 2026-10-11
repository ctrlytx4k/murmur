import AppKit
import os

/// The accent tints buttons, toggles and selection, and nothing else. Status colors never change.
public nonisolated enum Accent: String, CaseIterable, Sendable {
    case ice, clear, lilac, mint, graphite, system

    public var name: String {
        switch self {
        case .ice: "Ice"
        case .clear: "Clear"
        case .lilac: "Lilac"
        case .mint: "Mint"
        case .graphite: "Graphite"
        case .system: "Follow system"
        }
    }

    private var palette: (fill: (UInt32, UInt32), text: (UInt32, UInt32), on: (UInt32, UInt32))? {
        switch self {
        case .ice: ((0x0A64D8, 0x6CB6FF), (0x0A5FC0, 0x8CCBFF), (0xFFFFFF, 0x04172E))
        case .clear: ((0x3C4150, 0xE3E6EE), (0x2E3340, 0xF0F2F8), (0xFFFFFF, 0x14161C))
        case .lilac: ((0x6B4FD8, 0xB9A6FF), (0x5A3FD0, 0xC9BCFF), (0xFFFFFF, 0x150A3A))
        case .mint: ((0x08776A, 0x5FD9C4), (0x076A5F, 0x7FE5D2), (0xFFFFFF, 0x02231E))
        case .graphite: ((0x55555B, 0xB4B4BC), (0x4A4A50, 0xC8C8D0), (0xFFFFFF, 0x16161A))
        case .system: nil
        }
    }

    func fill(dark: Bool) -> NSColor { palette.map { Tokens.hex(dark ? $0.fill.1 : $0.fill.0) } ?? .controlAccentColor }
    func text(dark: Bool) -> NSColor { palette.map { Tokens.hex(dark ? $0.text.1 : $0.text.0) } ?? .controlAccentColor }
    func onFill(dark: Bool) -> NSColor { palette.map { Tokens.hex(dark ? $0.on.1 : $0.on.0) } ?? .white }
    func soft(dark: Bool) -> NSColor { fill(dark: dark).withAlphaComponent(dark ? 0.15 : 0.10) }

    /// The accent every token resolves against. Colors are resolved while drawing, so this is lock-protected.
    static var current: Accent {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }

    private static let box = OSAllocatedUnfairLock<Accent>(initialState: .ice)
}
