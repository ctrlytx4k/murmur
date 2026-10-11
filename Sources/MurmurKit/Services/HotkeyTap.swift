import AppKit
import Carbon.HIToolbox
import os

/// What the tap callback needs to know. Read and written under a lock, off the main actor.
nonisolated struct TapConfig: Sendable {
    var bindings: HotkeyBindings?
    var recording = false
    var dictationDown = false
    /// Double-tap tracking, in event-timestamp nanoseconds. Zero means "nothing pending".
    var tapDownAt: UInt64 = 0
    var lastTapAt: UInt64 = 0
}

nonisolated enum TapOutput: Equatable, Sendable {
    case event(HotkeyEvent)
    case action(HotkeyAction)
}

/// The whole decision the callback makes, as a pure function so it can be tested without a real tap.
nonisolated enum HotkeyDecision {
    /// Device-dependent modifier bits, to tell left from right and press from release.
    static let modifierMasks: [UInt16: UInt64] = [54: 0x10, 55: 0x08, 56: 0x02, 60: 0x04, 58: 0x20, 61: 0x40, 59: 0x01, 62: 0x2000, 63: 0x80_0000]
    /// Command, Option, Control, Shift. Same bit positions in CGEventFlags and NSEvent.ModifierFlags.
    static let relevantModifiers: UInt64 = 0x1E_0000
    /// A tap is a press shorter than this; a double-tap is two taps closer together than `doubleTapGap`.
    static let tapLength: UInt64 = 350_000_000
    static let doubleTapGap: UInt64 = 450_000_000

    /// The flag shared by the left and right versions of a modifier key.
    static func modifierFlag(_ keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 58, 61: 0x8_0000
        case 54, 55: 0x10_0000
        case 59, 62: 0x4_0000
        case 56, 60: 0x2_0000
        case 63: 0x80_0000
        default: nil
        }
    }

    /// Returns what to report, and whether to swallow the event so the front app never sees it.
    static func decide(type: CGEventType, keyCode: UInt16, flags: UInt64, autorepeat: Bool, time: UInt64 = 0, config: inout TapConfig) -> (output: TapOutput?, swallow: Bool) {
        guard let bindings = config.bindings else { return (nil, false) }
        let dictation = bindings.dictation
        let modifiers = UInt(flags & relevantModifiers)

        switch type {
        case .keyDown:
            // A modifier used with another key is a shortcut or an accent, not a tap.
            config.tapDownAt = 0
            config.lastTapAt = 0
            if config.recording {
                if keyCode == UInt16(kVK_Escape) { return (.event(.cancel), true) }
                if bindings.returnCommits, keyCode == UInt16(kVK_Return), modifiers == 0 { return (.event(.commit), true) }
            }
            if !dictation.isModifierOnly, keyCode == dictation.keyCode, modifiers == dictation.modifiers {
                if autorepeat || config.dictationDown { return (nil, true) }
                config.dictationDown = true
                return (.event(.down), true)
            }
            guard !autorepeat else { return (nil, false) }
            for (shortcut, action) in [(bindings.cycleMode, HotkeyAction.cycleMode), (bindings.reinsert, .reinsertLast), (bindings.history, .openHistory)] {
                if !shortcut.isModifierOnly, keyCode == shortcut.keyCode, modifiers == shortcut.modifiers { return (.action(action), true) }
            }
        case .keyUp:
            // Modifiers are not checked: they are often released before the key.
            if !dictation.isModifierOnly, keyCode == dictation.keyCode, config.dictationDown {
                config.dictationDown = false
                return (.event(.up), true)
            }
        case .flagsChanged:
            if dictation.isDoubleTap, let flag = modifierFlag(dictation.keyCode) {
                guard modifierFlag(keyCode) == flag else {
                    config.tapDownAt = 0
                    config.lastTapAt = 0
                    return (nil, false)
                }
                let down = flags & flag != 0
                let alone = flags & relevantModifiers & ~flag == 0
                if down {
                    if alone, config.lastTapAt != 0, time &- config.lastTapAt < doubleTapGap {
                        // Second press, soon after a tap: that is the double-tap.
                        config.lastTapAt = 0
                        config.tapDownAt = 0
                        return (.event(.toggle), false)
                    }
                    config.tapDownAt = alone ? max(time, 1) : 0
                } else {
                    config.lastTapAt = config.tapDownAt != 0 && time &- config.tapDownAt < tapLength ? max(time, 1) : 0
                    config.tapDownAt = 0
                }
                return (nil, false)
            }
            if dictation.isModifierOnly, keyCode == dictation.keyCode, let mask = modifierMasks[keyCode] {
                let down = flags & mask != 0
                if down != config.dictationDown {
                    config.dictationDown = down
                    return (.event(down ? .down : .up), false)
                }
            }
        default:
            break
        }
        return (nil, false)
    }
}

/// State shared with the tap thread.
private nonisolated final class TapShared: @unchecked Sendable {
    let config = OSAllocatedUnfairLock(initialState: TapConfig())
    let port = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)
    let runLoop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    let deliver: @Sendable (TapOutput) -> Void
    init(deliver: @escaping @Sendable (TapOutput) -> Void) { self.deliver = deliver }
}

/// The callback does no real work: one locked decision, then it hands the result to the main queue.
private nonisolated func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let shared = Unmanaged<TapShared>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS switched the tap off. Switch it straight back on.
        shared.port.withLockUnchecked { if let port = $0 { CGEvent.tapEnable(tap: port, enable: true) } }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let flags = event.flags.rawValue
    let time = event.timestamp
    let result = shared.config.withLock { HotkeyDecision.decide(type: type, keyCode: keyCode, flags: flags, autorepeat: autorepeat, time: time, config: &$0) }
    if let output = result.output { shared.deliver(output) }
    return result.swallow ? nil : Unmanaged.passUnretained(event)
}

public nonisolated struct HotkeyUnavailable: Error {
    public init() {}
}

/// The global shortcut, via an event tap on its own thread so a busy main thread can never stall it.
/// It is an active tap (it swallows the shortcut so the front app does not also type it), which needs Accessibility.
public final class LiveHotkeyService: HotkeyService {
    public var onEvent: ((HotkeyEvent) -> Void)?
    public var onAction: ((HotkeyAction) -> Void)?

    private var shared: TapShared?
    private var watchdog: Timer?
    private var strikes = 0
    /// Whether the hardware key state can be believed for the current press. It is sampled when the
    /// press arrives: if the system already says "up" while we know the key is down, the reading is
    /// useless for this key and the watchdog stays out of the way.
    private var keyStateTrusted = false
    private var wakeObserver: NSObjectProtocol?

    public init() {}

    public var isRunning: Bool {
        shared?.port.withLockUnchecked { $0.map { CGEvent.tapIsEnabled(tap: $0) } } ?? false
    }

    public func start(bindings: HotkeyBindings) throws {
        stop()
        guard AXIsProcessTrusted() else { throw HotkeyUnavailable() }
        let shared = TapShared { [weak self] output in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(output) } }
        }
        shared.config.withLock { $0.bindings = bindings }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: hotkeyTapCallback, userInfo: Unmanaged.passUnretained(shared).toOpaque())
            shared.port.withLockUnchecked { $0 = port }
            guard let port else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            shared.runLoop.withLockUnchecked { $0 = CFRunLoopGetCurrent() }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "murmur.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        guard shared.port.withLockUnchecked({ $0 != nil }) else { throw HotkeyUnavailable() }
        self.shared = shared

        // A key-up can go missing (secure input, another tap). If we think the key is down but the
        // hardware says it is up twice in a row, report the release ourselves.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForMissedRelease() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer

        // Taps do not reliably survive sleep. Make a fresh one on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let bindings = self.shared?.config.withLock({ $0.bindings }) else { return }
                try? self.start(bindings: bindings)
            }
        }
    }

    public func update(bindings: HotkeyBindings) {
        shared?.config.withLock {
            if $0.bindings?.dictation != bindings.dictation {
                $0.dictationDown = false
                $0.tapDownAt = 0
                $0.lastTapAt = 0
            }
            $0.bindings = bindings
        }
    }

    public func setRecording(_ recording: Bool) {
        shared?.config.withLock { $0.recording = recording }
    }

    public func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        guard let shared else { return }
        shared.port.withLockUnchecked { port in
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            port = nil
        }
        shared.runLoop.withLockUnchecked { if let loop = $0 { CFRunLoopStop(loop) } }
        self.shared = nil
    }

    private func receive(_ output: TapOutput) {
        switch output {
        case .event(let event):
            if event == .down, let key = shared?.config.withLock({ $0.bindings?.dictation.keyCode }) {
                keyStateTrusted = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
                strikes = 0
            }
            onEvent?(event)
        case .action(let action): onAction?(action)
        }
    }

    private func checkForMissedRelease() {
        guard let shared else { return }
        let held: UInt16? = shared.config.withLock { $0.dictationDown ? $0.bindings?.dictation.keyCode : nil }
        guard let held, keyStateTrusted else { return strikes = 0 }
        if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(held)) {
            strikes = 0
        } else {
            strikes += 1
            if strikes >= 3 {
                strikes = 0
                shared.config.withLock { $0.dictationDown = false }
                onEvent?(.up)
            }
        }
    }
}
