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

/// Where the overlay window goes: the canvas frame, and which edge of it the card is pinned to.
nonisolated struct OverlayPlacement: Equatable {
    var origin: CGPoint
    /// True when the card hangs from the top of its canvas and grows downward.
    var growsDown: Bool

    /// Room kept between the card and the caret, and between the card and the screen edge.
    static let gap: CGFloat = 8
    /// The tallest the card gets, with a panel open.
    static let tallestCard: CGFloat = 240

    /// `visible` is the screen without the menu bar and the Dock. `caret` is only passed for "under the cursor";
    /// without one the card goes to the bottom, where it has always been.
    static func resolve(_ appearance: OverlayAppearance, canvas: CGSize, visible: CGRect, caret: CGRect?, margin: CGFloat) -> OverlayPlacement {
        let centered = (visible.midX - canvas.width / 2).rounded()
        if appearance.position == .underCursor, let caret {
            let lowest = visible.minX + gap - margin, highest = visible.maxX - gap + margin - canvas.width
            let x = max(lowest, min(caret.midX - canvas.width / 2, max(lowest, highest))).rounded()
            if caret.minY - gap - tallestCard >= visible.minY {
                return OverlayPlacement(origin: CGPoint(x: x, y: (caret.minY - gap + margin - canvas.height).rounded()), growsDown: true)
            }
            // No room under the line being typed: sit above it and grow upward.
            return OverlayPlacement(origin: CGPoint(x: x, y: (caret.maxY + gap - margin).rounded()), growsDown: false)
        }
        if appearance.position == .top {
            return OverlayPlacement(origin: CGPoint(x: centered, y: (visible.maxY - appearance.edgeDistance + margin - canvas.height).rounded()), growsDown: true)
        }
        return OverlayPlacement(origin: CGPoint(x: centered, y: (visible.minY + appearance.edgeDistance - margin).rounded()), growsDown: false)
    }
}

/// Shows the overlay card for as long as a take is in flight, where Settings › Overlay says.
final class OverlayController {
    private let panel = FloatingPanel(level: .statusBar, allowsKey: false)
    private let controller: DictationController
    private let settings: SettingsStore
    private let panels: OverlayPanelState
    private let view: AnyView
    private let caretRect: @MainActor () -> CGRect?
    private var growsDown: Bool?
    private var frame = NSRect.zero
    private var isShown = false
    /// Where the caret was when this take began. The card stays there for the whole take.
    private var caret: CGRect?
    private var lookedForCaret = false

    init(stores: Stores, actions: AppActions, caretRect: @escaping @MainActor () -> CGRect? = CaretLocator.caretRect) {
        self.controller = stores.controller
        self.settings = stores.settings
        self.panels = stores.overlay
        self.caretRect = caretRect
        self.view = AnyView(OverlayView(stores: stores).environment(\.appActions, actions))
        layout()
        observeChanges { [weak self] in self?.update() }
    }

    /// Wide enough for the large card and tall enough for the tallest state, plus shadow room.
    private static let canvas = CGSize(width: OverlayAppearance.Size.large.cardWidth + 2 * FloatingPanel.margin, height: 420)

    /// Runs on every change of the take or of the overlay settings, so a change in Settings moves a card that is showing.
    private func update() {
        if !controller.state.isRecording, panels.open != nil { panels.open = nil }
        let visible = controller.state != .idle
        if !visible {
            isShown = false
            caret = nil
            lookedForCaret = false
            _ = settings.overlay
            return panel.fadeOut()
        }
        isShown = true
        layout()
        panel.fadeIn()
    }

    /// The window is a fixed canvas and the card is pinned to one edge of it. At the bottom of the screen the
    /// bottom edge stays put and an open panel grows the card upward, clear of the Dock; at the top, and under
    /// the caret, it grows down.
    private func layout() {
        let appearance = settings.overlay
        if appearance.position == .underCursor, isShown, !lookedForCaret {
            lookedForCaret = true
            caret = caretRect()
            DebugLog.log(caret == nil ? "overlay: no caret reported, using the bottom" : "overlay: placed by the caret")
        }
        let anchor = appearance.position == .underCursor ? caret : nil
        guard let screen = screen(for: appearance, caret: anchor) else { return }
        let placement = OverlayPlacement.resolve(appearance, canvas: Self.canvas, visible: screen.visibleFrame, caret: anchor, margin: FloatingPanel.margin)
        frame = NSRect(origin: placement.origin, size: Self.canvas)
        if placement.growsDown != growsDown {
            growsDown = placement.growsDown
            panel.setContent(view, canvas: Self.canvas, alignment: placement.growsDown ? .top : .bottom) { [weak self] _ in self?.place() }
        } else {
            place()
        }
    }

    private func screen(for appearance: OverlayAppearance, caret: CGRect?) -> NSScreen? {
        if let caret, let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY)) }) { return screen }
        // NSScreen.main is the display with the window being typed into; the first screen is the one with the menu bar.
        return (appearance.display == .mainScreen ? NSScreen.screens.first : NSScreen.main) ?? NSScreen.main
    }

    private func place() {
        guard frame.width > 0, panel.frame != frame else { return }
        DebugLog.log("overlay placed at \(Int(frame.minX)),\(Int(frame.minY)) size \(Int(frame.width))x\(Int(frame.height))")
        panel.setFrame(frame, display: true, animate: false)
    }
}

/// Shows the meeting pill at the top center of the screen while a meeting records or transcribes, and for a
/// few seconds once it is ready. The pill can be dragged, and it never appears in a screen share.
final class MeetingPillController {
    private let panel = FloatingPanel(level: .statusBar, allowsKey: false)
    private let controller: MeetingController
    private let pill = MeetingPillState()
    private var wasBusy = false
    private var placed = false
    private var hide: Task<Void, Never>?

    init(stores: Stores, actions: AppActions) {
        controller = stores.meeting
        // Left out of screen sharing, screen recording and screenshots.
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.setContent(MeetingPillView(stores: stores, pill: pill).environment(\.appActions, actions), canvas: Self.canvas, alignment: .top) { [weak self] size in
            self?.place(size)
        }
        observeChanges { [weak self] in self?.update() }
    }

    private static let canvas = CGSize(width: 460, height: 36 + 2 * FloatingPanel.margin)

    private func update() {
        let busy = !controller.state.isIdle
        if busy {
            hide?.cancel()
            pill.finished = nil
        } else if wasBusy, let latest = controller.latest {
            // Done: say so for a moment, with a way to open it.
            pill.finished = latest
            hide?.cancel()
            hide = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.pill.finished = nil }
            }
        }
        wasBusy = busy
        if busy || pill.finished != nil { panel.fadeIn() } else { panel.fadeOut() }
    }

    /// Top center, just under the menu bar. Only the first time: after that it stays where it was dragged.
    private func place(_ size: CGSize) {
        guard !placed, size.width > 0, let screen = NSScreen.main else { return }
        placed = true
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: area.maxY - 6 - size.height + FloatingPanel.margin, width: size.width, height: size.height), display: true, animate: false)
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
    private static let canvas = CGSize(width: 340 + 2 * FloatingPanel.margin, height: 1000)

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
        GlassMenuPresenter.shared.close()
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
