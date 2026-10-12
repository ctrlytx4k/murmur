import AppKit
import SwiftUI

/// Wires the pieces together. Launch arguments:
///   --demo               simulated services, to walk through the interface
///   --onboarding         show onboarding even if it was completed
///   --snapshots <dir>    render every screen to PNG files and exit
///   --selftest <audio>   transcribe a file with both real engines, print the result, and exit
///   --matrix <file>      type a test sentence into Notes, Terminal, Safari and Chrome and write what happened
///   --icon <png>         draw the app icon at 1024 px, for scripts/icon.sh
///   --tour               with --demo: open each surface in turn, then quit (a smoke test)
public final class MurmurApp: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private var settings: SettingsStore!
    private var controller: DictationController!
    private var stores: Stores!
    private let navigation = SettingsNavigation()
    private var historyWindow: NSWindow?
    private var actions = AppActions()
    private var hotkeys: LiveHotkeyService?
    private var router: EngineRouter?
    private var lastSoundState: DictationState = .idle
    private var statusItem: StatusItemController!
    private var overlay: OverlayController!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var permissionPoll: Timer?
    private var isPreparingLanguage = false

    public init(arguments: [String] = CommandLine.arguments) {
        self.arguments = arguments
    }

    public static func main() {
        let app = NSApplication.shared
        let delegate = MurmurApp()
        if let index = delegate.arguments.firstIndex(of: "--selftest"), delegate.arguments.count > index + 1 {
            SelfTest.run(clip: delegate.arguments[index + 1])
            return
        }
        if let index = delegate.arguments.firstIndex(of: "--snapshots"), delegate.arguments.count > index + 1 {
            Snapshots.render(to: URL(fileURLWithPath: delegate.arguments[index + 1]))
            return
        }
        if let index = delegate.arguments.firstIndex(of: "--icon"), delegate.arguments.count > index + 1 {
            Snapshots.renderIcon(to: URL(fileURLWithPath: delegate.arguments[index + 1]))
            return
        }
        if let index = delegate.arguments.firstIndex(of: "--matrix"), delegate.arguments.count > index + 1 {
            InsertionMatrix.run(output: delegate.arguments[index + 1])
            return
        }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = arguments.contains("--demo")
        // The demo keeps its own settings and sample data, so it never mixes with real use.
        let defaults = demo ? (UserDefaults(suiteName: "app.murmur.Murmur.demo") ?? .standard) : .standard
        settings = SettingsStore(defaults: defaults)
        let history = HistoryStore(defaults: defaults)
        history.prune(retention: settings.retention)
        let dictionary = DictionaryStore(defaults: defaults)
        let catalog: ModelCatalog
        if demo {
            // Simulated services: nothing is recorded and nothing is typed.
            controller = DictationController(
                audio: DemoAudio(), engine: DemoEngine(), insertion: DemoInsertion(), permissions: DemoPermissions(),
                settings: settings, cleanup: DemoCleanup(), history: history, dictionary: dictionary,
                frontmostApp: { DictationController.systemFrontmostApp() ?? TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes") })
            catalog = ModelCatalog(parakeetStatus: .available)
        } else {
            let router = EngineRouter(settings: settings)
            let audio = LiveAudioCapture()
            controller = DictationController(
                audio: audio, engine: router, insertion: PasteInsertion(settings: settings), permissions: LivePermissionsService(),
                settings: settings, cleanup: AppleCleanup(), history: history, dictionary: dictionary)
            audio.onDeviceChange = { [weak self] message in self?.controller.noteDeviceChange(message) }
            catalog = ModelCatalog(parakeetStatus: router.parakeet.isInstalled ? .installed : .available)
            catalog.onDownload = { [weak self] _ in self?.prepareParakeet(download: true) }
            catalog.onPrepareLanguage = { [weak self] in self?.prepareLanguage() }
            self.router = router

            let hotkeys = LiveHotkeyService()
            hotkeys.onEvent = { [weak self] event in self?.handle(event) }
            hotkeys.onAction = { [weak self] action in self?.perform(action) }
            self.hotkeys = hotkeys
        }
        stores = Stores(
            controller: controller, settings: settings, dictionary: dictionary, history: history,
            network: NetworkLog(defaults: defaults), catalog: catalog, isDemo: demo)
        router?.apple.onAssetDownload = { [weak self] in
            guard let self, self.settings.logsNetworkActivity else { return }
            self.stores.network.record(host: "Apple (via macOS)", reason: "Speech language download", bytes: 0)
        }
        if demo {
            DemoData.seed(stores)
            settings.cleanupEnabled = true
            settings.modelID = "apple-speech"
        }

        NSApp.mainMenu = makeMainMenu()
        observeChanges { [weak self] in self?.applyAppearance() }

        actions = AppActions(
            openSettings: { [weak self] pane in self?.showSettings(pane) },
            openHistory: { [weak self] in self?.showHistory() },
            openOnboarding: { [weak self] permission in self?.showOnboarding(at: permission.map(OnboardingStep.step(for:)) ?? .welcome) },
            showAbout: { [weak self] in self?.showAbout() },
            showAcknowledgements: { [weak self] in self?.showAcknowledgements() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            quit: { NSApp.terminate(nil) })
        statusItem = StatusItemController(stores: stores, actions: actions)
        overlay = OverlayController(stores: stores, actions: actions)
        if !demo { observeChanges { [weak self] in self?.syncServices() } }

        // Permission state is never cached: re-read it while the app runs so the icon stays honest.
        let poll = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refreshPermissions() }
        }
        RunLoop.main.add(poll, forMode: .common)
        permissionPoll = poll

        if arguments.contains("--tour") {
            Task { await self.tour() }
        } else if !settings.hasCompletedOnboarding || arguments.contains("--onboarding") {
            showOnboarding(at: OnboardingStep(rawValue: settings.onboardingStep) ?? .welcome)
        }
    }

    /// Drives one take and opens every window, so a launch exercises the real panels, timers and monitors.
    private func tour() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await pause(1)
        statusItem.open()
        await pause(1.5)
        controller.start()
        await pause(1.5)
        // The overlay's panels: the card grows in place, the take keeps running, Esc closes the panel first.
        let collapsed = stores.overlay.cardFrame
        guard case .recording(let since) = controller.state else { return print("tour: FAILED, not recording") }
        stores.overlay.open = .mode
        await pause(1)
        let grown = stores.overlay.cardFrame
        var stillRecording = controller.state == .recording(since: since)
        print("tour: mode panel open, same take still recording \(stillRecording), card height \(Int(collapsed.height)) -> \(Int(grown.height)), bottom edge moved \(Int(grown.maxY - collapsed.maxY)), top edge moved \(Int(grown.minY - collapsed.minY))")
        perform(.selectMode(0))
        let picked = settings.mode
        await pause(0.5)
        print("tour: ⌥1 picked \(picked.label), panel collapsed \(stores.overlay.open == nil)")
        perform(.selectMode(1))
        stores.overlay.open = .actions
        await pause(0.6)
        handle(.cancel)
        stillRecording = controller.state.isRecording
        print("tour: first esc closed the panel \(stores.overlay.open == nil), still recording \(stillRecording)")
        handle(.cancel)
        print("tour: second esc cancelled the take \(controller.state == .idle)")
        await pause(0.5)
        controller.start()
        await pause(1.5)
        stores.overlay.open = .actions
        controller.stopAndInsert()
        await pause(0.3)
        print("tour: panel closed with the take \(stores.overlay.open == nil)")
        await pause(3.5)
        statusItem.close()
        for pane in SettingsPane.allCases {
            showSettings(pane)
            await pause(0.6)
        }
        showHistory()
        await pause(1.5)
        showOnboarding(at: .microphone)
        await pause(2)
        print("tour finished in state \(controller.state)")
        NSApp.terminate(nil)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again while it is already running (from Finder, Spotlight or the Dock) should
    /// show something. A menu bar app has no window by default, which reads as "it didn't open".
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if settings.hasCompletedOnboarding { showSettings(nil) } else { showOnboarding(at: OnboardingStep(rawValue: settings.onboardingStep) ?? .welcome) }
        }
        return true
    }

    // MARK: services

    /// Keeps the hotkey tap, the loaded speech model and the feedback sounds in step with settings,
    /// permissions and the dictation state. Re-runs whenever any of those change.
    private func syncServices() {
        guard let hotkeys, let router else { return }
        var bindings = settings.hotkeyBindings
        // A hands-free take ends with Return too, like toggle mode.
        if controller.isLatched { bindings.returnCommits = true }
        if hotkeys.isRunning {
            hotkeys.update(bindings: bindings)
        } else if controller.permissions.accessibility {
            // The tap needs Accessibility. This runs again the moment the permission is granted.
            try? hotkeys.start(bindings: bindings)
        }
        hotkeys.setRecording(controller.state.isRecording)
        hotkeys.setActionsOpen(stores.overlay.open == .actions)

        let state = controller.state
        if settings.soundsEnabled, state != lastSoundState {
            let names: (start: String, stop: String) = switch settings.soundSet {
            case .soft: ("Tink", "Pop")
            case .click: ("Morse", "Bottle")
            case .chime: ("Glass", "Hero")
            }
            if state.isRecording { NSSound(named: names.start)?.play() } else if lastSoundState.isRecording, state == .processing { NSSound(named: names.stop)?.play() }
        }
        lastSoundState = state

        if settings.modelID == "parakeet-v3" {
            if router.parakeet.isInstalled, !router.parakeet.isLoaded { prepareParakeet(download: false) }
        } else {
            _ = settings.language
            prepareLanguage()
        }
    }

    /// Gets the built-in engine's language files ready ahead of the first take, and keeps the catalog
    /// telling the truth about it for onboarding.
    private func prepareLanguage() {
        guard let router, !isPreparingLanguage else { return }
        let catalog = stores.catalog
        guard !router.apple.isPrepared else { return catalog.languageStatus = .ready }
        isPreparingLanguage = true
        catalog.languageStatus = .preparing
        Task {
            do {
                try await router.apple.prepare()
                self.isPreparingLanguage = false
                // The language may have been changed while the last one was being fetched.
                if router.apple.isPrepared {
                    DebugLog.log("built-in speech language ready")
                    catalog.languageStatus = .ready
                } else {
                    self.prepareLanguage()
                }
            } catch {
                self.isPreparingLanguage = false
                DebugLog.log("built-in speech language failed: \(error.localizedDescription)")
                catalog.languageStatus = .failed(router.apple.lastError ?? error.localizedDescription)
            }
        }
    }

    /// Loads Parakeet, downloading it first when asked. Progress shows in Settings and in the overlay.
    private func prepareParakeet(download: Bool) {
        guard let router, router.parakeet.progress == nil, !router.parakeet.isLoaded else { return }
        let catalog = stores.catalog
        if download {
            guard !settings.offlineMode else { return catalog.setStatus(.unavailable("Offline mode is on (Settings › Privacy)"), for: "parakeet-v3") }
            catalog.downloadError = nil
            catalog.setStatus(.downloading(0), for: "parakeet-v3")
        }
        Task {
            do {
                try await router.parakeet.prepare { progress in
                    if download { catalog.setStatus(.downloading(progress), for: "parakeet-v3") }
                }
                catalog.setStatus(.installed, for: "parakeet-v3")
                if download {
                    if self.settings.logsNetworkActivity {
                        self.stores.network.record(host: "huggingface.co", reason: "Model download · parakeet-v3", bytes: 480_000_000)
                    }
                    self.settings.modelID = "parakeet-v3"
                }
            } catch {
                if download { catalog.downloadError = "The download stopped: \(error.localizedDescription) Check your connection and try again." }
                catalog.setStatus(router.parakeet.isInstalled ? .installed : .available, for: "parakeet-v3")
            }
        }
    }

    /// The first Esc closes an open overlay panel; the take is only cancelled by the next one.
    private func handle(_ event: HotkeyEvent) {
        if event == .cancel, stores.overlay.open != nil { return stores.overlay.open = nil }
        controller.hotkey(event)
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .cycleMode: settings.mode = settings.mode.next
        case .reinsertLast: controller.reinsertLast()
        case .openHistory: showHistory()
        case .selectMode(let index):
            guard DictationMode.offered.indices.contains(index) else { return }
            settings.mode = DictationMode.offered[index]
            if stores.overlay.open != nil { stores.overlay.collapseSoon() }
        }
    }

    /// No automatic updates yet: this opens the releases page, in the browser, only when asked.
    @objc private func checkForUpdates() {
        NSWorkspace.shared.open(AppInfo.releases)
    }

    private func showAcknowledgements() {
        let bundled = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")
        NSWorkspace.shared.open(bundled ?? URL(string: "https://github.com/FluidInference/FluidAudio")!)
    }

    // MARK: appearance

    private func applyAppearance() {
        NSApp.appearance = switch settings.appearance {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // MARK: windows

    @objc private func showSettingsFromMenu() { showSettings(nil) }

    private func showSettings(_ pane: SettingsPane?) {
        if let pane { navigation.pane = pane }
        if settingsWindow == nil {
            settingsWindow = makeWindow(SettingsView(stores: stores, navigation: navigation).environment(\.appActions, actions), title: "Murmur Settings")
        }
        present(settingsWindow)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(HistoryView(stores: stores).environment(\.appActions, actions), title: "Murmur History")
        }
        present(historyWindow)
    }

    private func showOnboarding(at step: OnboardingStep) {
        onboardingWindow?.close()
        let view = OnboardingView(stores: stores, step: step) { [weak self] in
            self?.onboardingWindow?.close()
        }
        let window = makeWindow(view, title: "Welcome to Murmur")
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        onboardingWindow = window
        present(window)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Local-first voice dictation.\nNo account, no tracking, no cloud.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        ])
    }

    private func makeWindow(_ view: some View, title: String) -> NSWindow {
        let host = NSHostingView(rootView: view)
        // The content draws under the title bar. Without this the hosting view keeps the
        // title bar inset, which leaves an unpainted strip along the bottom of the window.
        host.safeAreaRegions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar lowers the traffic lights so they sit inside the sidebar, as in the mockup.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(Tokens.windowBackground)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // When System Settings relaunches us ("Quit & Reopen") macOS can refuse the activation,
        // which would leave the window hidden behind Settings and look like the app never came back.
        window?.orderFrontRegardless()
    }

    // MARK: menu

    /// A menu bar app still needs a main menu for ⌘Q, ⌘, ⌘W and editing keys in its windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Murmur", action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",").target = self
        app.addItem(withTitle: "History", action: #selector(showHistory), keyEquivalent: "y").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenuItem(window))
        return main
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
