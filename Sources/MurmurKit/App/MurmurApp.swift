import AppKit
import SwiftUI

/// Wires the pieces together. Launch arguments:
///   --demo               simulated services, to walk through the interface
///   --onboarding         show onboarding even if it was completed
///   --snapshots <dir>    render every screen to PNG files and exit
///   --tour               with --demo: open each surface in turn, then quit (a smoke test)
public final class MurmurApp: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private var settings: SettingsStore!
    private var controller: DictationController!
    private var statusItem: StatusItemController!
    private var overlay: OverlayController!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var permissionPoll: Timer?

    public init(arguments: [String] = CommandLine.arguments) {
        self.arguments = arguments
    }

    public static func main() {
        let app = NSApplication.shared
        let delegate = MurmurApp()
        if let index = delegate.arguments.firstIndex(of: "--snapshots"), delegate.arguments.count > index + 1 {
            Snapshots.render(to: URL(fileURLWithPath: delegate.arguments[index + 1]))
            return
        }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = arguments.contains("--demo")
        settings = SettingsStore()
        // The real audio, transcription and insertion services arrive once the spike report says go.
        // Until then every take ends in a visible "not available" error rather than pretending.
        controller = DictationController(
            audio: demo ? DemoAudio() : UnavailableAudioCapture(),
            engine: demo ? DemoEngine() : UnavailableTranscriptionEngine(),
            insertion: demo ? DemoInsertion() : UnavailableTextInsertion(),
            permissions: demo ? DemoPermissions() : LivePermissionsService(),
            settings: settings,
            frontmostApp: {
                // In the demo there is always somewhere for the text to "go".
                DictationController.systemFrontmostApp() ?? (demo ? TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes") : nil)
            })

        NSApp.mainMenu = makeMainMenu()
        observeChanges { [weak self] in self?.applyAppearance() }

        let actions = AppActions(
            openSettings: { [weak self] in self?.showSettings() },
            openOnboarding: { [weak self] permission in self?.showOnboarding(at: permission.map(OnboardingStep.step(for:)) ?? .welcome) },
            showAbout: { [weak self] in self?.showAbout() },
            quit: { NSApp.terminate(nil) })
        statusItem = StatusItemController(controller: controller, settings: settings, actions: actions)
        overlay = OverlayController(controller: controller, settings: settings)

        // Permission state is never cached: re-read it while the app runs so the icon stays honest.
        let poll = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refreshPermissions() }
        }
        RunLoop.main.add(poll, forMode: .common)
        permissionPoll = poll

        if arguments.contains("--tour") {
            Task { await self.tour() }
        } else if !settings.hasCompletedOnboarding || arguments.contains("--onboarding") {
            showOnboarding(at: .welcome)
        }
    }

    /// Drives one take and opens every window, so a launch exercises the real panels, timers and monitors.
    private func tour() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await pause(1)
        statusItem.open()
        await pause(1.5)
        controller.start()
        await pause(3)
        controller.stopAndInsert()
        await pause(3.5)
        statusItem.close()
        showSettings()
        await pause(2)
        showOnboarding(at: .microphone)
        await pause(2)
        print("tour finished in state \(controller.state)")
        NSApp.terminate(nil)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: appearance

    private func applyAppearance() {
        NSApp.appearance = switch settings.appearance {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(SettingsView(controller: controller, settings: settings), title: "Murmur Settings")
        }
        present(settingsWindow)
    }

    private func showOnboarding(at step: OnboardingStep) {
        onboardingWindow?.close()
        let view = OnboardingView(controller: controller, settings: settings, step: step) { [weak self] in
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
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.ignoresSafeArea())
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: menu

    /// A menu bar app still needs a main menu for ⌘Q, ⌘, ⌘W and editing keys in its windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Murmur", action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
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
