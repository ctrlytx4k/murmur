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
            date: Date().addingTimeInterval(-120), appName: "Notes", mode: .cleaned)
        let noMic = PermissionSnapshot(microphone: false, accessibility: true, inputMonitoring: true)
        let noAX = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: true)

        func make(_ state: DictationState, permissions: PermissionSnapshot = .allGranted, silent: Bool = false, last: Transcription? = nil, toggle: Bool = false, notice: String? = nil, empty: Bool = false) -> Stores {
            let defaults = UserDefaults(suiteName: "murmur-snapshots-\(UUID().uuidString)")!
            let settings = SettingsStore(defaults: defaults)
            if toggle { settings.behavior = .toggle }
            settings.mode = .cleaned
            settings.cleanupEnabled = true
            let history = HistoryStore(defaults: defaults)
            let controller = DictationController(
                audio: DemoAudio(), engine: DemoEngine(), insertion: DemoInsertion(),
                permissions: DemoPermissions(permissions), settings: settings, cleanup: DemoCleanup(), errorHold: .seconds(3600))
            controller.loadPreview(
                state: state, target: notes, levels: state.isRecording ? (silent ? nil : levels) : nil,
                isSilent: silent, last: last, canUndo: last != nil, permissions: permissions, deviceNotice: notice)
            let stores = Stores(
                controller: controller, settings: settings, dictionary: DictionaryStore(defaults: defaults), history: history,
                network: NetworkLog(defaults: defaults), catalog: ModelCatalog(parakeetStatus: .available), isDemo: !empty)
            if !empty { DemoData.seed(stores) }
            return stores
        }

        var shots: [(String, AnyView)] = []
        func add(_ name: String, _ view: some View) { shots.append((name, AnyView(view))) }
        func settingsShot(_ name: String, _ stores: Stores, _ pane: SettingsPane, tab: DictionaryPane.Tab = .dictionary) {
            let navigation = SettingsNavigation()
            navigation.pane = pane
            navigation.dictionaryTab = tab
            add(name, SettingsView(stores: stores, navigation: navigation))
        }

        let recording = DictationState.recording(since: Date().addingTimeInterval(-7))
        var st = make(.idle, last: last)
        add("dropdown-idle", DropdownView(stores: st))
        add("dropdown-model-expanded", DropdownView(stores: st, expanded: .model))
        add("dropdown-microphone-expanded", DropdownView(stores: st, expanded: .microphone))
        add("menu-overlay-mode", GlassMenu(items: [
            GlassMenuItem(title: "Raw", detail: DictationMode.raw.summary, symbol: DictationMode.raw.symbol),
            GlassMenuItem(title: "Cleaned up", detail: DictationMode.cleaned.summary, symbol: DictationMode.cleaned.symbol, isSelected: true),
            .separator,
            GlassMenuItem(title: "Insert now", keys: "↩"),
            GlassMenuItem(title: "Copy instead", keys: "⌘C", isDisabled: true, disabledReason: "Nothing to copy"),
            .separator,
            GlassMenuItem(title: "Cancel take", keys: "esc", isDestructive: true),
        ]))
        add("menu-microphone", GlassMenu(items: [
            .header("Input"),
            GlassMenuItem(title: "System Default", detail: "Follows System Settings · MacBook Pro Microphone"),
            GlassMenuItem(title: "MacBook Pro Microphone", detail: "Built-in"),
            GlassMenuItem(title: "USB mic", detail: "USB", isSelected: true),
            .separator,
            GlassMenuItem(title: "Sound settings…", isAccent: true),
        ]))
        add("menu-language-scrolling", GlassMenu(items: SettingsStore.languages.map { GlassMenuItem(title: $0, isSelected: $0 == "English") }, maxHeight: 256))
        add("menu-microphone-disconnected", GlassMenu(items: [
            .header("Input"),
            GlassMenuItem(title: "System Default", detail: "Follows System Settings · MacBook Pro Microphone"),
            GlassMenuItem(title: "MacBook Pro Microphone", detail: "Built-in"),
            GlassMenuItem(title: "USB mic", detail: "Not connected · using default", isSelected: true, isDisabled: true),
        ]))
        add("menu-plain", GlassMenu(items: SettingsStore.Retention.allCases.map { GlassMenuItem(title: $0.rawValue, isSelected: $0 == .month) }))
        st = make(recording)
        add("dropdown-recording", DropdownView(stores: st))
        add("overlay-listening", OverlayView(stores: st))
        st = make(.idle, permissions: noMic, last: last)
        add("dropdown-permission-missing", DropdownView(stores: st))
        st = make(recording, silent: true, toggle: true)
        add("overlay-no-sound", OverlayView(stores: st))
        st = make(recording, notice: "USB mic disconnected. Now using MacBook Pro Microphone.")
        add("overlay-mic-disconnected", OverlayView(stores: st))
        st = make(.processing)
        add("overlay-processing", OverlayView(stores: st))
        st = make(.inserted(InsertionSummary(appName: "Notes", wordCount: 18)))
        add("overlay-inserted", OverlayView(stores: st))
        st = make(.error(.insertionFailed(appName: "Notes")))
        add("overlay-error", OverlayView(stores: st))
        st = make(.error(.secureInput))
        add("overlay-secure-field", OverlayView(stores: st))
        st = make(.error(.modelNotReady(name: "parakeet-v3", progress: 0.62)))
        add("overlay-model-downloading", OverlayView(stores: st))

        st = make(.idle)
        settingsShot("settings-general", st, .general)
        settingsShot("settings-hotkeys", st, .hotkeys)
        settingsShot("settings-voice-engine", st, .voiceEngine)
        settingsShot("settings-ai-cleanup", st, .cleanup)
        settingsShot("settings-dictionary", st, .dictionary)
        settingsShot("settings-snippets", st, .dictionary, tab: .snippets)
        settingsShot("settings-privacy", st, .privacy)
        settingsShot("settings-advanced", st, .advanced)
        add("history", HistoryView(stores: st))
        st = make(.idle)
        st.settings.historyShortcut = Shortcut(keyCode: 49, modifiers: .control)
        settingsShot("settings-hotkeys-conflict", st, .hotkeys)
        st = make(.idle, empty: true)
        settingsShot("settings-dictionary-empty", st, .dictionary)
        add("history-empty", HistoryView(stores: st))

        st = make(.idle)
        add("dialog-hotkey-conflict", HotkeyConflictDialog(settings: st.settings))
        add("dialog-update-available", UpdateAvailableView(
            version: "1.1", currentVersion: "1.0.0", size: "18 MB", notes: "[Release notes for 1.1 appear here]", installsAutomatically: .constant(true)))

        add("onboarding-1-welcome", OnboardingView(stores: st, step: .welcome))
        add("onboarding-2-microphone-granted", OnboardingView(stores: st, step: .microphone))
        add("onboarding-4-input-monitoring-granted", OnboardingView(stores: st, step: .inputMonitoring))
        add("onboarding-5-speech-model", OnboardingView(stores: st, step: .model))
        add("onboarding-6-try-it", OnboardingView(stores: st, step: .tryIt))
        st = make(.idle, permissions: noAX)
        add("onboarding-3-accessibility-waiting", OnboardingView(stores: st, step: .accessibility))
        st = make(.idle, permissions: PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: false))
        add("onboarding-4-input-monitoring-waiting", OnboardingView(stores: st, step: .inputMonitoring))
        st = make(.idle)
        st.catalog.setStatus(.downloading(0.62), for: "parakeet-v3")
        st.catalog.languageStatus = .preparing
        add("onboarding-5-speech-model-preparing", OnboardingView(stores: st, step: .model))

        for (name, view) in shots {
            for (suffix, appearance, backdrop) in [
                ("light", NSAppearance.Name.aqua, NSColor(srgbRed: 0.87, green: 0.90, blue: 0.96, alpha: 1)),
                ("dark", NSAppearance.Name.darkAqua, NSColor(srgbRed: 0.09, green: 0.10, blue: 0.19, alpha: 1)),
            ] {
                let isWindow = ["settings", "onboarding", "history", "dialog-update"].contains { name.hasPrefix($0) }
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

    /// The app icon as a 1024 px PNG: the same tile the interface draws, inside the usual margin.
    static func renderIcon(to url: URL) {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: AppIconTile(size: 824).frame(width: 1024, height: 1024))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return print("Could not draw the icon") }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path)")
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
