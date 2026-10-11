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

    private var onPlace: ((CGSize) -> Void)?
    private var canvas: CGSize?

    /// The content changes size while it is on screen, so the panel is a fixed, transparent
    /// canvas and the content is pinned to one edge inside it, so nothing ever resizes or moves the window:
    /// a card that grows simply grows within the canvas.
    func setContent(
        _ view: some View, canvas: CGSize, alignment: Alignment, onBackgroundClick: (() -> Void)? = nil, onPlace: @escaping (CGSize) -> Void
    ) {
        let root = view
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
            .padding(Self.margin)
            .frame(width: canvas.width, height: canvas.height, alignment: alignment)
            .background {
                // Clicks on the empty canvas normally fall through to the app behind. If one lands here anyway, treat it as a click outside.
                if let onBackgroundClick { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onBackgroundClick) }
            }
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = []
        contentViewController = host
        self.onPlace = onPlace
        self.canvas = canvas
        sizeToContent()
    }

    /// Sizes the panel to its canvas and asks the owner to place it. Called each time it is shown,
    /// because the anchor (the menu bar icon, the screen) may have moved.
    func sizeToContent() {
        if let canvas { onPlace?(canvas) }
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
        panel.setContent(OverlayView(stores: stores).environment(\.appActions, actions), canvas: Self.canvas, alignment: .bottom) { [weak self] size in
            self?.place(size)
        }
        observeChanges { [weak self] in self?.update() }
    }

    /// Wide enough for the 400 pt card and tall enough for the tallest state, plus shadow room.
    private static let canvas = CGSize(width: 448, height: 300)

    private func update() {
        if controller.state == .idle { panel.fadeOut() } else { panel.fadeIn() }
    }

    /// Centered, 64 pt above the Dock.
    private func place(_ size: CGSize) {
        guard size.width > 0, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(x: (area.midX - size.width / 2).rounded(), y: area.minY + 64 - FloatingPanel.margin)
        let frame = NSRect(origin: origin, size: size)
        guard panel.frame != frame else { return }
        DebugLog.log("overlay placed at \(Int(frame.minX)),\(Int(frame.minY)) size \(Int(frame.width))x\(Int(frame.height))")
        panel.setFrame(frame, display: true, animate: false)
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
        actions.closeDropdown = { [weak self] in self?.close(immediately: true) }
        panel.setContent(
            DropdownView(stores: stores).environment(\.appActions, actions), canvas: Self.canvas, alignment: .top,
            onBackgroundClick: { [weak self] in self?.close() }
        ) { [weak self] size in
            self?.place(size)
        }
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel)
        observeChanges { [weak self] in self?.render() }
    }

    /// The 340 pt dropdown plus shadow room, and taller than its tallest state. The dropdown changes height
    /// with the dictation state; resizing the window to follow made it jump and ride up over the menu bar.
    private static let canvas = CGSize(width: 340 + 2 * FloatingPanel.margin, height: 860)

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

    func close(immediately: Bool = false) {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        if immediately {
            // Gives keyboard focus back to the app behind at once, before any text is inserted.
            panel.alphaValue = 0
            panel.orderOut(nil)
        } else {
            panel.fadeOut()
        }
    }

    @objc private func panelResignedKey() {
        // A click on the menu bar item itself is handled by toggle().
        if let button = item.button, let window = button.window, window.frame.contains(NSEvent.mouseLocation) { return }
        close()
    }

    /// Centered under the icon. Near the screen edge it slides in to stay on screen,
    /// which gives the right-aligned placement the mockup shows. Runs when the dropdown opens,
    /// so it stays put while open even if the icon moves (the recording timer widens it).
    private func place(_ size: CGSize) {
        guard size.width > 0, let buttonWindow = item.button?.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.frame
        let margin = FloatingPanel.margin
        var x = anchor.midX - size.width / 2
        x = min(x, screen.visibleFrame.maxX - size.width + margin - 8)
        x = max(x, screen.visibleFrame.minX - margin + 8)
        let y = anchor.minY - 6 - size.height + margin
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true, animate: false)
    }
}
