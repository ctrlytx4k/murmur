import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click to arm, then press the shortcut. Accepts a key with modifiers, a function
/// key, or one modifier pressed and released on its own. Esc cancels.
struct KeyRecorder: View {
    @Binding var shortcut: Shortcut
    var name = "Dictation shortcut"
    /// Draws the amber conflict ring.
    var flagged = false
    @State private var armed = false
    @State private var heldCaps: [String] = []
    @State private var monitor: Any?
    @State private var loneModifier: UInt16?
    /// A modifier that was just tapped once. A second tap within the window makes it a double-tap shortcut.
    @State private var firstTap: UInt16?
    @State private var pendingSingle: DispatchWorkItem?

    private var conflict: Bool { flagged }

    var body: some View {
        Button {
            armed ? disarm() : arm()
        } label: {
            HStack(spacing: 3) {
                if armed {
                    ForEach(heldCaps, id: \.self) { Keycap(text: $0) }
                    Text(heldCaps.isEmpty ? "Type a shortcut…" : "…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.accentText)
                } else {
                    ForEach(shortcut.keycaps, id: \.self) { Keycap(text: $0) }
                }
            }
            .frame(width: 160, height: 32)
            .background(armed ? Tokens.accentSoft : (conflict ? Tokens.warningSoft : Tokens.control), in: Pill())
            .overlay(Pill().strokeBorder(armed ? Tokens.accentText : (conflict ? Tokens.warning : Tokens.stroke), lineWidth: armed ? 2 : (conflict ? 1.5 : 0.5)))
            .contentShape(Pill())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(shortcut.spokenName)")
        .accessibilityHint(armed ? "Press the new shortcut, or Escape to cancel" : "Click to record a new shortcut")
        .onDisappear(perform: disarm)
    }

    private func arm() {
        armed = true
        heldCaps = []
        loneModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil  // swallow: nothing should type or beep while recording
        }
    }

    private func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        armed = false
        heldCaps = []
        firstTap = nil
        pendingSingle?.cancel()
        pendingSingle = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        switch event.type {
        case .flagsChanged:
            if flags.isEmpty {
                // Everything released. A modifier pressed alone becomes the shortcut.
                if let key = loneModifier {
                    pendingSingle?.cancel()
                    if let first = firstTap, HotkeyDecision.modifierFlag(first) == HotkeyDecision.modifierFlag(key) {
                        // Tapped twice: a double-tap shortcut, either side.
                        shortcut = Shortcut(keyCode: first, modifiers: [], isDoubleTap: true)
                        disarm()
                    } else {
                        // Wait a moment in case a second tap is coming.
                        firstTap = key
                        heldCaps = [(Shortcut.modifierSymbols[key] ?? "") + " …tap again for ×2"]
                        let single = DispatchWorkItem {
                            shortcut = Shortcut(keyCode: key, modifiers: [], isModifierOnly: true)
                            disarm()
                        }
                        pendingSingle = single
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: single)
                    }
                }
            } else {
                loneModifier = (heldCaps.isEmpty || firstTap != nil) ? event.keyCode : nil
                if firstTap == nil { heldCaps = Shortcut(keyCode: 0, modifiers: flags).keycaps.dropLast().map { $0 } }
            }
        case .keyDown:
            loneModifier = nil
            firstTap = nil
            pendingSingle?.cancel()
            if event.keyCode == UInt16(kVK_Escape) { return disarm() }
            let isFunctionKey = event.modifierFlags.contains(.function) && event.specialKey != nil
            // A bare letter would fire every time it is typed, so ask for a modifier.
            guard !flags.isEmpty || isFunctionKey else { return NSSound.beep() }
            shortcut = Shortcut(keyCode: event.keyCode, modifiers: flags)
            disarm()
        default:
            break
        }
    }
}
