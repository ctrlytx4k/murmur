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
        let noMic = PermissionSnapshot(microphone: false, accessibility: true)
        let noAX = PermissionSnapshot(microphone: true, accessibility: false)

        func make(_ state: DictationState, permissions: PermissionSnapshot = .allGranted, silent: Bool = false, last: Transcription? = nil, toggle: Bool = false, notice: String? = nil, empty: Bool = false) -> Stores {
            let defaults = UserDefaults(suiteName: "murmur-snapshots-\(UUID().uuidString)")!
            let settings = SettingsStore(defaults: defaults)
            if toggle { settings.behavior = .toggle }
            settings.mode = .cleaned
            settings.cleanupEnabled = true
            let history = HistoryStore(defaults: defaults)
            let providers = ProviderStore(defaults: defaults, keys: MemoryKeyStore())
            let controller = DictationController(
                audio: DemoAudio(), engine: DemoEngine(), insertion: DemoInsertion(),
                permissions: DemoPermissions(permissions), settings: settings, cleanup: DemoCleanup(), providers: providers, errorHold: .seconds(3600))
            controller.loadPreview(
                state: state, target: notes, levels: state.isRecording ? (silent ? nil : levels) : nil,
                isSilent: silent, last: last, canUndo: last != nil, permissions: permissions, deviceNotice: notice)
            let meetings = MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-snapshots-\(UUID().uuidString)"))
            let meeting = MeetingController(
                audio: DemoMeetingAudio(), engine: DemoEngine(), store: meetings, settings: settings, permissions: DemoPermissions(permissions),
                openTrack: { _ in DemoMeetingTrack() })
            let stores = Stores(
                controller: controller, settings: settings, dictionary: DictionaryStore(defaults: defaults), history: history, stats: StatsStore(defaults: defaults), providers: providers,
                network: NetworkLog(defaults: defaults), catalog: ModelCatalog(parakeetStatus: .available), meetings: meetings, meeting: meeting, isDemo: !empty)
            if !empty {
                DemoData.seed(stores)
                // The day the Stats board was drawn on, so the numbers can be checked against it.
                stores.stats.replaceAll(StatsFixture.rows())
            }
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
        let statsDay = StatsFixture.mockupToday
        func mainShot(_ name: String, _ stores: Stores, _ tab: MainTab, hovered: Int? = nil, table: Bool = false) {
            let navigation = MainNavigation()
            navigation.tab = tab
            add(name, MainWindowView(stores: stores, navigation: navigation, today: statsDay, hoveredBar: hovered, showsTable: table))
        }
        add("dropdown-idle", DropdownView(stores: st, statsToday: statsDay))
        add("dropdown-model-expanded", DropdownView(stores: st, expanded: .model, statsToday: statsDay))
        add("dropdown-microphone-expanded", DropdownView(stores: st, expanded: .microphone, statsToday: statsDay))
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
        st = make(recording)
        st.overlay.open = .mode
        add("overlay-mode-open", OverlayView(stores: st))
        st = make(recording)
        st.overlay.open = .actions
        add("overlay-actions-open", OverlayView(stores: st))
        st = make(.idle, permissions: noMic, last: last)
        add("dropdown-permission-missing", DropdownView(stores: st, statsToday: statsDay))
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

        // Overlay appearance: every material on every backdrop, the three sizes, and the pane.
        for material in OverlayAppearance.Material.allCases {
            for backdrop in PreviewBackdrop.allCases {
                st = make(recording)
                st.settings.overlay.material = material
                add("overlay-material-\(material.rawValue)-on-\(backdrop.rawValue)", OverlayPreviewStage(stores: st, backdrop: backdrop).frame(width: 598))
            }
        }
        for size in OverlayAppearance.Size.allCases {
            st = make(recording)
            st.settings.overlay.size = size
            add("overlay-size-\(size.rawValue)", OverlayView(stores: st, sample: .finished))
            st = make(.processing)
            st.settings.overlay.size = size
            add("overlay-size-\(size.rawValue)-processing", OverlayView(stores: st))
        }
        for scheme in [OverlayAppearance.CardScheme.light, .dark] {
            st = make(recording)
            st.settings.overlay.cardScheme = scheme
            add("overlay-card-\(scheme.rawValue)", OverlayView(stores: st, sample: .finished))
        }
        st = make(recording)
        st.settings.overlay.showTargetApp = false
        st.settings.overlay.showKeyHints = false
        st.settings.overlay.showTimer = false
        st.settings.overlay.showTranscript = false
        add("overlay-everything-hidden", OverlayView(stores: st))
        st = make(.idle)
        settingsShot("settings-overlay", st, .overlay)
        // The pane is taller than the window, so here it is in full.
        add("overlay-pane-full", VStack(alignment: .leading, spacing: 18) { OverlayPane(stores: st) }
            .padding(28).frame(width: 654).background(Tokens.windowBackground).foregroundStyle(Tokens.label))
        st = make(.idle)
        st.settings.overlay.position = .underCursor
        do {
            let navigation = SettingsNavigation()
            navigation.pane = .overlay
            add("settings-overlay-reduce-transparency", SettingsView(stores: st, navigation: navigation).environment(\.solidOverlay, true))
        }

        st = make(.idle)
        settingsShot("settings-general", st, .general)
        settingsShot("settings-hotkeys", st, .hotkeys)
        settingsShot("settings-voice-engine", st, .voiceEngine)
        settingsShot("settings-ai-cleanup", st, .cleanup)
        settingsShot("settings-dictionary", st, .dictionary)
        settingsShot("settings-snippets", st, .dictionary, tab: .snippets)
        settingsShot("settings-privacy", st, .privacy)
        settingsShot("settings-advanced", st, .advanced)
        mainShot("history", st, .history)
        // Meetings: the recorder, a recording in progress, and a transcribed meeting.
        mainShot("meetings-recorder", st, .meetings)
        add("meetings-transcript", MainWindowMeeting(stores: st, selection: st.meetings.meetings.first?.id))
        do {
            let live = make(.idle)
            live.meeting.start()
            add("meetings-recording", MainWindowMeeting(stores: live, selection: nil))
            add("dropdown-meeting-recording", DropdownView(stores: live, statsToday: statsDay))
            let waiting = make(.idle, empty: true)
            var failed = Meeting(title: "Meeting, 9:30 AM", date: Date().addingTimeInterval(-3600), duration: 754, includesCallAudio: true)
            failed.problem = "The speech model (parakeet-v3) is still downloading."
            waiting.meetings.add(failed)
            add("meetings-not-transcribed", MainWindowMeeting(stores: waiting, selection: failed.id))
        }
        mainShot("overview", st, .overview, hovered: 8)
        mainShot("overview-table", st, .overview, table: true)
        // Bring your own provider: the pane with a cloud provider in use, the three sheets and the overlay.
        let claude = ProviderConfig(id: "claude", kind: .anthropic, model: "claude-haiku-5-5")
        func withProviders(_ state: DictationState, stayLocal: Bool = false) -> Stores {
            let stores = make(state)
            stores.providers.save(ProviderConfig(id: "ollama", kind: .localServer, name: "Ollama", model: "llama3.2:3b"), key: nil)
            stores.providers.save(claude, key: "snapshot")
            stores.providers.save(ProviderConfig(id: "work", kind: .openAICompatible, name: "Work server", model: "qwen2.5-7b", baseURL: "https://llm.internal:8080/v1"), key: nil)
            stores.providers.grantConsentAndSelect("claude")
            stores.providers.stayLocalApps = [StayLocalApp(bundleIdentifier: "com.apple.mail", name: "Mail"), StayLocalApp(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")]
            if stayLocal { stores.providers.stayLocalApps.append(StayLocalApp(bundleIdentifier: "com.apple.Notes", name: "Notes")) }
            return stores
        }
        st = withProviders(.idle)
        do {
            let navigation = SettingsNavigation()
            navigation.pane = .cleanup
            add("settings-ai-cleanup-cloud", SettingsView(stores: st, navigation: navigation, cleanupStatus: ["ollama": "Running", "work": "Not reachable"]))
        }
        settingsShot("settings-privacy-cloud", st, .privacy)
        add("sheet-provider-add", AddProviderSheet(router: st.controller.cleanupRouter, found: [ProviderConfig(kind: .localServer, name: "Ollama")]))
        add("sheet-provider-setup", ProviderSetupSheet(
            stores: st, provider: ProviderConfig(kind: .anthropic, model: "claude-haiku-5-5"), isNew: true, key: "snapshot-not-a-key",
            models: [ProviderAPI.Model(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", line: "haiku", supportsEffort: true)],
            phase: .passed(CleanupRouter.TestResult(sent: CleanupRouter.testSentence, received: "So, we should ship it Friday.", seconds: 0.7, provider: claude))))
        add("sheet-provider-setup-choose", ProviderSetupSheet(
            stores: st, provider: ProviderConfig(kind: .openAI), isNew: true, key: "snapshot-not-a-key",
            models: ["babbage-002", "chatgpt-image-latest", "gpt-3.5-turbo", "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini", "gpt-4o-transcribe", "tts-1", "whisper-1"].map { ProviderAPI.Model(id: $0, name: $0) },
            phase: .chooseModel))
        add("sheet-provider-setup-empty", ProviderSetupSheet(stores: st, provider: ProviderConfig(kind: .openAICompatible), isNew: true))
        add("sheet-provider-consent", ProviderConsentSheet(provider: claude))
        add("overlay-cloud-listening", OverlayView(stores: withProviders(recording)))
        add("overlay-cloud-processing", OverlayView(stores: withProviders(.processing)))
        add("overlay-stay-local", OverlayView(stores: withProviders(recording, stayLocal: true)))
        add("overlay-stay-local-processing", OverlayView(stores: withProviders(.processing, stayLocal: true)))
        add("overlay-cloud-fallback", OverlayView(stores: withProviders(.inserted(InsertionSummary(appName: "Notes", wordCount: 18, note: "Claude didn’t answer, cleaned up on this Mac")))))

        st = make(.idle)
        st.settings.historyShortcut = Shortcut(keyCode: 49, modifiers: .control)
        settingsShot("settings-hotkeys-conflict", st, .hotkeys)
        st = make(.idle, empty: true)
        settingsShot("settings-dictionary-empty", st, .dictionary)
        mainShot("history-empty", st, .history)
        mainShot("meetings-empty", st, .meetings)
        mainShot("overview-empty", st, .overview)
        add("dropdown-first-run", DropdownView(stores: st))
        st = make(.idle, empty: true)
        st.settings.keepStats = false
        mainShot("overview-stats-off", st, .overview)

        st = make(.idle)
        add("dialog-hotkey-conflict", HotkeyConflictDialog(settings: st.settings))
        add("dialog-update-available", UpdateAvailableView(
            version: "1.1", currentVersion: "1.0.0", size: "18 MB", notes: "[Release notes for 1.1 appear here]", installsAutomatically: .constant(true)))

        add("onboarding-1-welcome", OnboardingView(stores: st, step: .welcome))
        add("onboarding-2-microphone-granted", OnboardingView(stores: st, step: .microphone))
        add("onboarding-4-speech-model", OnboardingView(stores: st, step: .model))
        add("onboarding-5-try-it", OnboardingView(stores: st, step: .tryIt))
        st = make(.idle, permissions: noAX)
        add("onboarding-3-accessibility-waiting", OnboardingView(stores: st, step: .accessibility))
        st = make(.idle)
        st.catalog.setStatus(.downloading(0.62), for: "parakeet-v3")
        st.catalog.languageStatus = .preparing
        add("onboarding-4-speech-model-preparing", OnboardingView(stores: st, step: .model))

        for (name, view) in shots {
            for (suffix, appearance, backdrop) in [
                ("light", NSAppearance.Name.aqua, NSColor(srgbRed: 0.87, green: 0.90, blue: 0.96, alpha: 1)),
                ("dark", NSAppearance.Name.darkAqua, NSColor(srgbRed: 0.09, green: 0.10, blue: 0.19, alpha: 1)),
            ] {
                let isWindow = ["settings", "onboarding", "history", "overview", "meetings", "sheet", "dialog-update"].contains { name.hasPrefix($0) }
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

    /// The main window on its Meetings tab, with a chosen meeting open.
    private struct MainWindowMeeting: View {
        let stores: Stores
        let selection: UUID?
        var body: some View {
            VStack(spacing: 0) {
                RectSegments(options: [(MainTab.overview, "Overview"), (MainTab.history, "History"), (MainTab.meetings, "Meetings")], selection: .constant(.meetings), label: "View")
                    .frame(height: 52)
                MeetingsView(stores: stores, selection: selection)
            }
            .frame(width: 1144, height: 800)
            .background(Tokens.windowBackground)
            .foregroundStyle(Tokens.label)
        }
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
