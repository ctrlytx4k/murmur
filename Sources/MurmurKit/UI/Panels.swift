import AppKit
import Observation
import SwiftUI

/// Re-runs `read` whenever any observable value it touched changes.
@MainActor
func observeChanges(_ read: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking {
        read()
    } onChange: {
        Task { @MainActor in observeChanges(read) }
    }
}

/// A borderless, transparent panel for glass surfaces that float over other apps.
final class FloatingPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Room around the content for its shadow.
    static let margin: CGFloat = 24

    init(level: NSWindow.Level, allowsKey: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.allowsKey = allowsKey
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private var onResize: ((CGSize) -> Void)?

    func setContent(_ view: some View, onResize: @escaping (CGSize) -> Void) {
        let root = view
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
            .padding(Self.margin)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
        contentView = NSHostingView(rootView: root)
        self.onResize = onResize
        sizeToContent()
    }

    /// The panel starts at zero size, and a zero-size window never lays out its content,
    /// so the size has to be asked for rather than waited on.
    func sizeToContent() {
        guard let size = contentView?.fittingSize, size.width > 0 else { return }
        onResize?(size)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func fadeIn() {
        guard !isVisible || alphaValue < 1 else { return }
        sizeToContent()
        if !isVisible { alphaValue = Self.reduceMotion ? 1 : 0 }
        if allowsKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0 : Tokens.Motion.cardInOut
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.reduceMotion ? 0 : Tokens.Motion.cardInOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Skip if it was shown again while fading.
                if let self, self.alphaValue == 0 { self.orderOut(nil) }
            }
        })
    }
}

/// Shows the overlay card near the bottom of the screen for as long as a take is in flight.
final class OverlayController {
    private let panel = FloatingPanel(level: .statusBar, allowsKey: false)
    private let controller: DictationController

    init(stores: Stores, actions: AppActions) {
        self.controller = stores.controller
        panel.setContent(OverlayView(stores: stores).environment(\.appActions, actions)) { [weak self] size in
            self?.place(size)
        }
        observeChanges { [weak self] in self?.update() }
    }

    private func update() {
        if controller.state == .idle { panel.fadeOut() } else { panel.fadeIn() }
    }

    /// Centered, 64 pt above the Dock.
    private func place(_ size: CGSize) {
        guard size.width > 0, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 64 - FloatingPanel.margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Owns the menu bar item: the icon for each state and the dropdown under it.
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = FloatingPanel(level: .popUpMenu, allowsKey: true)
    private let controller: DictationController
    private var animation: Timer?
    private var animationStart = Date()
    private var shown: MenuBarState?
    private var outsideClicks: Any?

    init(stores: Stores, actions: AppActions) {
        self.controller = stores.controller
        super.init()
        var actions = actions
        actions.closeDropdown = { [weak self] in self?.close() }
        panel.setContent(DropdownView(stores: stores).environment(\.appActions, actions)) { [weak self] size in
            self?.place(size)
        }
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel)
        observeChanges { [weak self] in self?.render() }
    }

    var menuBarState: MenuBarState {
        switch controller.state {
        case .recording: .recording
        case .processing: .processing
        case .error: .needsAttention
        case .idle, .inserted: controller.permissions.allGranted ? .idle : .permissionMissing
        }
    }

    // MARK: icon

    private func render() {
        let state = menuBarState
        guard state != shown else { return }
        shown = state
        animation?.invalidate()
        animation = nil
        animationStart = Date()
        drawFrame()
        item.button?.toolTip = state.accessibilityLabel
        item.button?.setAccessibilityLabel(state.accessibilityLabel)

        let animated = (state == .recording || state == .processing) && !FloatingPanel.reduceMotion
        if animated || state == .recording {
            // Recording always ticks for the timer; the pulse only runs when motion is allowed.
            let timer = Timer(timeInterval: animated ? 0.1 : 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.drawFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            animation = timer
        }
    }

    private func drawFrame() {
        guard let state = shown, let button = item.button else { return }
        let elapsed = Date().timeIntervalSince(animationStart)
        var phase: CGFloat = 0
        if !FloatingPanel.reduceMotion {
            let period = state == .recording ? Tokens.Motion.pulse : 0.9
            phase = CGFloat(elapsed.truncatingRemainder(dividingBy: period) / period)
        }
        button.image = StatusIcon.image(for: state, phase: phase)
        if case .recording(let since) = controller.state {
            let seconds = max(0, Int(Date().timeIntervalSince(since)))
            button.title = " \(seconds / 60):\(String(format: "%02d", seconds % 60))"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: dropdown

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    func open() {
        controller.refreshPermissions()
        panel.fadeIn()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        panel.fadeOut()
    }

    @objc private func panelResignedKey() {
        // A click on the menu bar item itself is handled by toggle().
        if let button = item.button, let window = button.window, window.frame.contains(NSEvent.mouseLocation) { return }
        close()
    }

    /// Centered under the icon. Near the screen edge it slides in to stay on screen,
    /// which gives the right-aligned placement the mockup shows.
    private func place(_ size: CGSize) {
        guard size.width > 0, let buttonWindow = item.button?.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.frame
        let margin = FloatingPanel.margin
        var x = anchor.midX - size.width / 2
        x = min(x, screen.visibleFrame.maxX - size.width + margin - 8)
        x = max(x, screen.visibleFrame.minX - margin + 8)
        let y = anchor.minY - 6 - size.height + margin
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
