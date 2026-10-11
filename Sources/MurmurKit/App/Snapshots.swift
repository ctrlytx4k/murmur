import AppKit
import SwiftUI

/// Renders every screen, light and dark, to PNG files so the build can be checked
/// against design/murmur-mockups.html without clicking through the app.
/// Glass is drawn as its opaque tint here: offscreen there is nothing behind it to refract.
enum Snapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let levels: [Float] = (0..<DictationController.levelCount).map { i in
            let r = Float((i * 7919 + 13) % 100) / 100
            return r < 0.4 ? 0 : r * r * (0.3 + 0.7 * min(1, Float(i) / 34))
        }
        let notes = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        let last = Transcription(
            text: "Sounds good. I’ll send the revised draft Thursday morning and loop in the design team before the review.",
            date: Date().addingTimeInterval(-120), appName: "Notes")
        let noMic = PermissionSnapshot(microphone: false, accessibility: true, inputMonitoring: true)
        let noAX = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: true)

        func make(_ state: DictationState, permissions: PermissionSnapshot = .allGranted, silent: Bool = false, last: Transcription? = nil, toggle: Bool = false)
            -> (DictationController, SettingsStore)
        {
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-snapshots-\(UUID().uuidString)")!)
            if toggle { settings.behavior = .toggle }
            let controller = DictationController(
                audio: DemoAudio(), engine: DemoEngine(), insertion: DemoInsertion(),
                permissions: DemoPermissions(permissions), settings: settings, errorHold: .seconds(3600))
            controller.loadPreview(
                state: state, target: notes, levels: state.isRecording ? (silent ? nil : levels) : nil,
                isSilent: silent, last: last, canUndo: last != nil, permissions: permissions)
            return (controller, settings)
        }

        var shots: [(String, AnyView)] = []
        func add(_ name: String, _ view: some View) { shots.append((name, AnyView(view))) }

        let recording = DictationState.recording(since: Date().addingTimeInterval(-7))
        var (c, s) = make(.idle, last: last)
        add("dropdown-idle", DropdownView(controller: c, settings: s))
        (c, s) = make(recording)
        add("dropdown-recording", DropdownView(controller: c, settings: s))
        add("overlay-listening", OverlayView(controller: c, settings: s))
        (c, s) = make(.idle, permissions: noMic, last: last)
        add("dropdown-permission-missing", DropdownView(controller: c, settings: s))
        (c, s) = make(recording, silent: true, toggle: true)
        add("overlay-no-sound", OverlayView(controller: c, settings: s))
        (c, s) = make(.processing)
        add("overlay-processing", OverlayView(controller: c, settings: s))
        (c, s) = make(.inserted(InsertionSummary(appName: "Notes", wordCount: 18)))
        add("overlay-inserted", OverlayView(controller: c, settings: s))
        (c, s) = make(.error(.insertionFailed(appName: "Notes")))
        add("overlay-error", OverlayView(controller: c, settings: s))
        (c, s) = make(.error(.secureInput))
        add("overlay-secure-field", OverlayView(controller: c, settings: s))

        (c, s) = make(.idle)
        add("settings-general", SettingsView(controller: c, settings: s, pane: .general))
        add("settings-hotkeys", SettingsView(controller: c, settings: s, pane: .hotkeys))
        (c, s) = make(.idle)
        s.shortcut = Shortcut(keyCode: 49, modifiers: .control)
        add("settings-hotkeys-conflict", SettingsView(controller: c, settings: s, pane: .hotkeys))

        (c, s) = make(.idle)
        add("onboarding-1-welcome", OnboardingView(controller: c, settings: s, step: .welcome))
        add("onboarding-2-microphone-granted", OnboardingView(controller: c, settings: s, step: .microphone))
        add("onboarding-4-input-monitoring-granted", OnboardingView(controller: c, settings: s, step: .inputMonitoring))
        add("onboarding-5-try-it", OnboardingView(controller: c, settings: s, step: .tryIt))
        (c, s) = make(.idle, permissions: noAX)
        add("onboarding-3-accessibility-waiting", OnboardingView(controller: c, settings: s, step: .accessibility))

        for (name, view) in shots {
            for (suffix, appearance, backdrop) in [
                ("light", NSAppearance.Name.aqua, NSColor(srgbRed: 0.87, green: 0.90, blue: 0.96, alpha: 1)),
                ("dark", NSAppearance.Name.darkAqua, NSColor(srgbRed: 0.09, green: 0.10, blue: 0.19, alpha: 1)),
            ] {
                let isWindow = name.hasPrefix("settings") || name.hasPrefix("onboarding")
                let content = view
                    .clipShape(RoundedRectangle(cornerRadius: isWindow ? Tokens.Radius.window : 0, style: .continuous))
                    .padding(28)
                    .background(Color(nsColor: backdrop))
                    .environment(\.flatGlass, true)
                write(content, appearance: appearance, to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        print("Wrote \(shots.count * 2) snapshots to \(directory.path)")
    }

    private static func write(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        // Let onAppear, layout and AppKit-backed controls settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
