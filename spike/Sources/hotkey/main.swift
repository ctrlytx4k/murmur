// Experiment 1: push-to-talk hotkey via CGEventTap.
//
//   hotkey --scenario hold30 [--key 61] [--tap listen|active] [--duration 60]
//          [--synth 200 --synth-interval-ms 15]
//
// Ctrl-C (or --duration) ends the run and writes a summary row.

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SpikeSupport
import os

let args = Args()
let keyCode = Int64(args.int("key", 61))  // 61 = right Option
let scenario = args.string("scenario", "adhoc")
let activeTap = args.string("tap", "listen") == "active"
let log = ResultLog(experiment: "hotkey", label: scenario, args: args)

// Device-dependent modifier bits (IOLLEvent.h NX_DEVICE*KEYMASK). Needed to tell
// left from right and to know whether a flagsChanged is a press or a release.
let modifierMasks: [Int64: UInt64] = [
    54: 0x10, 55: 0x08, 56: 0x02, 60: 0x04, 58: 0x20, 61: 0x40, 59: 0x01, 62: 0x2000, 63: 0x80_0000,
]
let modifierMask = modifierMasks[keyCode]

struct RawEvent {
    var type: UInt32
    var keyCode: Int64 = 0
    var flags: UInt64 = 0
    var autorepeat = false
    var eventNanos: UInt64 = 0
    var seenNanos: UInt64
}

let pending = OSAllocatedUnfairLock<[RawEvent]>(initialState: [])
let consumer = DispatchQueue(label: "hotkey.consumer")
let wake = DispatchSource.makeUserDataAddSource(queue: consumer)

// The callback only copies a few fields and enqueues. No logging, no allocation
// beyond the occasional array growth, no calls back into the window server.
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    var raw = RawEvent(type: type.rawValue, seenNanos: monoNanos())
    if type != .tapDisabledByTimeout && type != .tapDisabledByUserInput {
        raw.keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        raw.flags = event.flags.rawValue
        raw.autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        raw.eventNanos = event.timestamp
    }
    let queued = raw
    pending.withLock { $0.append(queued) }
    wake.add(data: 1)
    return Unmanaged.passUnretained(event)
}

// MARK: tap lifecycle (main thread)

var tap: CFMachPort?
var tapSource: CFRunLoopSource?
var tapCreations = 0

func createTap(reason: String) {
    if let old = tap {
        CGEvent.tapEnable(tap: old, enable: false)
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(old)
    }
    let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
    let t0 = monoMillis()
    tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: activeTap ? .defaultTap : .listenOnly,
        eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
    guard let tap else {
        log.write("tap_create_failed", [
            "reason": reason,
            "listen_access": CGPreflightListenEventAccess(),
            "accessibility": AXIsProcessTrusted(),
            "cause": activeTap ? "active tap needs Accessibility" : "listen-only tap needs Input Monitoring",
        ])
        return
    }
    tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    tapCreations += 1
    log.write("tap_created", [
        "reason": reason, "took_ms": round2(monoMillis() - t0), "count": tapCreations,
        // tapCreate can succeed without the permission and then deliver nothing.
        "listen_access_at_creation": CGPreflightListenEventAccess(),
    ])
}

// MARK: consumer state (consumer queue)

var isDown = false
var downNanos: UInt64 = 0
var downs = 0, ups = 0, missedUps = 0, strayUps = 0, autorepeats = 0
var disabledByTimeout = 0, disabledByUserInput = 0
var watchdogReleases = 0, watchdogStrikes = 0
var rawEvents = 0
var holdsMs: [Double] = []
var deliveryMs: [Double] = []

func keyEvent(down: Bool, _ e: RawEvent) {
    let delivery = Double(e.seenNanos &- e.eventNanos) / 1e6
    deliveryMs.append(delivery)
    var row: [String: Any] = ["event_ns": e.eventNanos, "delivery_ms": round2(delivery)]
    if down {
        if isDown {
            missedUps += 1
            log.write("missed_up", ["detected_by": "second_down"])
        }
        isDown = true
        downNanos = e.eventNanos
        downs += 1
        row["n"] = downs
        log.write("down", row)
    } else {
        ups += 1
        if isDown {
            let hold = Double(e.eventNanos &- downNanos) / 1e6
            holdsMs.append(hold)
            row["hold_ms"] = round2(hold)
        } else {
            strayUps += 1
            row["stray"] = true
        }
        isDown = false
        row["n"] = ups
        log.write("up", row)
    }
}

func handle(_ e: RawEvent) {
    rawEvents += 1
    switch CGEventType(rawValue: e.type) {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let timeout = e.type == CGEventType.tapDisabledByTimeout.rawValue
        if timeout { disabledByTimeout += 1 } else { disabledByUserInput += 1 }
        DispatchQueue.main.async {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.write("tap_reenabled", [
                "cause": timeout ? "timeout" : "user_input",
                "after_ms": round2(Double(monoNanos() &- e.seenNanos) / 1e6),
            ])
        }
    case .flagsChanged:
        guard e.keyCode == keyCode, let modifierMask else { return }
        keyEvent(down: e.flags & modifierMask != 0, e)
    case .keyDown:
        guard e.keyCode == keyCode, modifierMask == nil else { return }
        if e.autorepeat { autorepeats += 1 } else { keyEvent(down: true, e) }
    case .keyUp:
        guard e.keyCode == keyCode, modifierMask == nil else { return }
        keyEvent(down: false, e)
    default:
        break
    }
}

wake.setEventHandler {
    let batch = pending.withLock { items -> [RawEvent] in
        let copy = items
        items.removeAll(keepingCapacity: true)
        return copy
    }
    batch.forEach(handle)
}
wake.resume()

// Watchdog: if we think the key is down but the HID state says it is up on two
// polls in a row, the key-up never reached the tap.
let watchdog = DispatchSource.makeTimerSource(queue: consumer)
watchdog.schedule(deadline: .now() + 0.1, repeating: 0.1)
watchdog.setEventHandler {
    guard isDown else { watchdogStrikes = 0; return }
    if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode)) {
        watchdogStrikes = 0
    } else {
        watchdogStrikes += 1
        if watchdogStrikes >= 2 {
            missedUps += 1
            watchdogReleases += 1
            isDown = false
            watchdogStrikes = 0
            log.write("missed_up", ["detected_by": "watchdog_poll"])
        }
    }
}
watchdog.resume()

// MARK: environment polling (main thread)

var lastSecure: Bool?
var lastFront: String?
var lastEnabled: Bool?
let envTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
    let secure = IsSecureEventInputEnabled()
    if secure != lastSecure {
        lastSecure = secure
        log.write("secure_input", ["enabled": secure])
    }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    if front != lastFront {
        lastFront = front
        log.write("frontmost", ["bundle": front])
    }
    if let tap {
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        if enabled != lastEnabled {
            lastEnabled = enabled
            log.write("tap_enabled_state", ["enabled": enabled])
        }
    }
}
RunLoop.main.add(envTimer, forMode: .common)

let wsCenter = NSWorkspace.shared.notificationCenter
wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
    log.write("will_sleep")
}
wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    let enabledBefore = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    log.write("did_wake", ["tap_enabled_before_recreate": enabledBefore])
    if !args.flag("no-recreate") { createTap(reason: "wake") }
}

// MARK: summary and exit

func finish() {
    consumer.sync {
        let batch = pending.withLock { $0 }
        batch.forEach(handle)
        log.write("summary", [
            "scenario": scenario,
            "key": keyCode,
            "tap": activeTap ? "active" : "listen",
            "downs": downs, "ups": ups,
            // Zero here means the tap delivered nothing at all (usually a missing permission),
            // which is different from "the key was never pressed".
            "raw_events_any_key": rawEvents,
            "missed_ups": missedUps, "missed_ups_caught_by_watchdog": watchdogReleases,
            "stray_ups": strayUps, "autorepeats": autorepeats,
            "still_down_at_exit": isDown,
            "tap_disabled_timeout": disabledByTimeout,
            "tap_disabled_user_input": disabledByUserInput,
            "tap_creations": tapCreations,
            "hold_ms_min": round2(holdsMs.min() ?? 0),
            "hold_ms_median": round2(median(holdsMs)),
            "hold_ms_max": round2(holdsMs.max() ?? 0),
            "delivery_ms_median": round2(median(deliveryMs)),
            "delivery_ms_max": round2(deliveryMs.max() ?? 0),
            "synth_expected": args.int("synth", 0),
            "secure_input_at_exit": IsSecureEventInputEnabled(),
        ])
    }
    exit(0)
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { finish() }
sigint.resume()

// MARK: go

log.write("permissions", [
    "listen_access": CGPreflightListenEventAccess(),
    "accessibility": AXIsProcessTrusted(),
    "tap_mode": activeTap ? "active" : "listen",
])
if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
if activeTap && !AXIsProcessTrusted() {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
}

createTap(reason: "launch")
if tap == nil {
    log.write("summary", ["scenario": scenario, "result": "no tap, see tap_create_failed"])
    exit(2)
}

let duration = args.double("duration", 0)
if duration > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
}

// Optional: post synthetic taps of the same key so the counting can be checked
// without a human. Posting needs Accessibility for the launching process.
let synth = args.int("synth", 0)
if synth > 0 {
    let interval = useconds_t(args.int("synth-interval-ms", 15) * 1000)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<synth {
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down)
                else { continue }
                if let modifierMask {
                    ev.type = .flagsChanged
                    ev.flags = CGEventFlags(rawValue: down ? (CGEventFlags.maskAlternate.rawValue | modifierMask) : 0)
                }
                ev.post(tap: .cghidEventTap)
                usleep(interval)
            }
        }
        log.write("synth_done", ["taps": synth])
        if duration == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() } }
    }
}

FileHandle.standardError.write(Data("Listening for key \(keyCode). Ctrl-C to stop and write the summary.\n".utf8))
RunLoop.main.run()
