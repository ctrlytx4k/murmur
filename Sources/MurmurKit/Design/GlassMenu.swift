import AppKit
import Observation
import SwiftUI

// One glass menu for the whole app, in place of the system menu (SwiftUI Menu and Picker open an
// NSMenu, which takes no styling). One level only: there are no submenus anywhere.

/// One row of a glass menu.
struct GlassMenuItem: Identifiable {
    enum Kind {
        case row, separator, header
        /// A view of its own at the foot of the menu, such as a small segmented control.
        case custom(AnyView)
    }

    let id = UUID()
    var kind = Kind.row
    var title = ""
    /// A second line under the title. Makes the row 48 pt tall.
    var detail: String?
    /// An SF Symbol shown in a 30 pt tile. Without one the row has a slot for the selection dot.
    var symbol: String?
    /// A key hint on the right, such as "esc".
    var keys: String?
    var isSelected = false
    var isDisabled = false
    /// Why a disabled row is disabled, shown on the right and read by VoiceOver.
    var disabledReason: String?
    var isDestructive = false
    /// Title in the accent color, for a row that leads somewhere ("Manage models…").
    var isAccent = false
    var isMonospaced = false
    var action: () -> Void = {}

    static var separator: GlassMenuItem { GlassMenuItem(kind: .separator) }
    static func header(_ title: String) -> GlassMenuItem { GlassMenuItem(kind: .header, title: title) }
    static func custom(_ view: some View) -> GlassMenuItem { GlassMenuItem(kind: .custom(AnyView(view))) }

    var isRow: Bool { if case .row = kind { true } else { false } }
    var isTall: Bool { detail != nil || symbol != nil }
}

// MARK: panel

/// The window a glass menu lives in. It never becomes key and never activates Murmur, so the app
/// being dictated into keeps the keyboard; keys reach an open menu through a monitor instead.
final class GlassMenuPanel: NSPanel {
    /// Room around the menu for its shadow.
    static let margin: CGFloat = 30

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Above the overlay and above the menu bar dropdown, whichever opened it.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
}

/// Reports where the pointer is, also while another app is active (SwiftUI hover does not then).
private final class GlassMenuTrackingView: NSView {
    var onMove: ((CGPoint?) -> Void)?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMove?(nil) }
}

// MARK: presenter

/// Opens and closes the one glass menu that can be on screen.
@Observable
final class GlassMenuPresenter {
    static let shared = GlassMenuPresenter()

    /// Which trigger's menu is open, so the trigger can show it.
    private(set) var openID: String?
    /// The row under the pointer, and the row the arrow keys are on.
    fileprivate(set) var hovered: UUID?
    fileprivate(set) var focused: UUID?

    @ObservationIgnored private var panel: GlassMenuPanel?
    @ObservationIgnored private var items: [GlassMenuItem] = []
    @ObservationIgnored fileprivate var frames: [UUID: CGRect] = [:]
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var endsWithTake = false
    @ObservationIgnored private var lastClosed: (id: String, at: Date)?

    var isOpen: Bool { openID != nil }

    /// Opens the menu under `anchor`, or closes it if that trigger's menu is already open.
    /// `keyboard` is for menus opened from Murmur's own windows; an overlay menu is mouse only,
    /// because the keyboard belongs to the app being dictated into.
    func toggle(id: String, anchor: NSView?, keyboard: Bool, endsWithTake: Bool = false, items: [GlassMenuItem]) {
        if openID == id { return close() }
        // The click that closed this trigger's menu also lands on the trigger. That is a close, not a reopen.
        if let lastClosed, lastClosed.id == id, Date().timeIntervalSince(lastClosed.at) < 0.3 { return }
        close()
        guard let anchor, let window = anchor.window, !items.isEmpty else { return }
        let trigger = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero

        self.items = items
        self.endsWithTake = endsWithTake
        frames = [:]
        hovered = nil
        focused = nil

        // Measure first, to know whether it fits below the trigger.
        let margin = GlassMenuPanel.margin
        let measured = NSHostingView(rootView: GlassMenu(items: items, opensUpward: false, presenter: self)).fittingSize
        let size = CGSize(width: measured.width - 2 * margin, height: measured.height - 2 * margin)
        let opensUpward = trigger.minY - 6 - size.height < area.minY && trigger.maxY + 6 + size.height <= area.maxY
        var x = trigger.maxX - size.width
        x = max(area.minX + 4, min(x, area.maxX - size.width - 4))
        var y = opensUpward ? trigger.maxY + 6 : trigger.minY - 6 - size.height
        y = max(area.minY + 4, min(y, area.maxY - size.height - 4))

        let panel = self.panel ?? GlassMenuPanel()
        self.panel = panel
        let tracking = GlassMenuTrackingView()
        tracking.onMove = { [weak self] point in self?.pointerMoved(to: point) }
        let host = NSHostingView(rootView: GlassMenu(items: items, opensUpward: opensUpward, presenter: self))
        host.frame = NSRect(origin: .zero, size: measured)
        host.autoresizingMask = [.width, .height]
        host.setAccessibilityRole(.menu)
        tracking.frame = host.frame
        tracking.addSubview(host)
        panel.contentView = tracking
        panel.appearance = window.effectiveAppearance
        panel.setFrame(NSRect(x: x - margin, y: y - margin, width: measured.width, height: measured.height), display: true)
        panel.orderFrontRegardless()
        openID = id

        // A click anywhere else closes it. Clicks in other apps arrive on the global monitor.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.close() }
            }
            return event
        }) { monitors.append(monitor) }
        if keyboard, let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) ?? false } ? nil : event
        }) { monitors.append(monitor) }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard let id = openID else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        lastClosed = (id, Date())
        openID = nil
        items = []
        hovered = nil
        focused = nil
    }

    /// The take stopped or was cancelled: a menu opened from the overlay goes with it.
    func takeEnded() {
        if endsWithTake { close() }
    }

    /// Esc while recording closes an overlay menu instead of cancelling the take. Returns whether it did.
    func closeOverlayMenu() -> Bool {
        guard isOpen, endsWithTake else { return false }
        close()
        return true
    }

    fileprivate func activate(_ item: GlassMenuItem) {
        guard item.isRow, !item.isDisabled else { return }
        close()
        item.action()
    }

    private func pointerMoved(to point: CGPoint?) {
        let row = point.flatMap { point in items.first { $0.isRow && !$0.isDisabled && frames[$0.id]?.contains(point) == true }?.id }
        if row != hovered { hovered = row }
        // Once the pointer is in charge, the keyboard ring goes away.
        if row != nil, focused != nil { focused = nil }
    }

    /// ↑ ↓ move, ↩ picks, a letter jumps to the next row starting with it, esc closes.
    private func keyDown(_ event: NSEvent) -> Bool {
        let rows = items.filter { $0.isRow && !$0.isDisabled }
        let current = rows.firstIndex { $0.id == (focused ?? hovered) }
        switch event.keyCode {
        case 53:
            close()
        case 125:
            focused = rows.isEmpty ? nil : rows[min((current ?? -1) + 1, rows.count - 1)].id
        case 126:
            focused = rows.isEmpty ? nil : rows[max((current ?? rows.count) - 1, 0)].id
        case 36, 76, 49:
            if let current { activate(rows[current]) }
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1, letter.first?.isLetter == true || letter.first?.isNumber == true
            else { return false }
            let after = rows.indices.map { ($0 + (current ?? -1) + 1) % rows.count }
            if let match = after.first(where: { rows[$0].title.lowercased().hasPrefix(letter) }) { focused = rows[match].id }
        }
        return true
    }
}

// MARK: content

private struct GlassMenuRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// The menu itself: rows on glass, one step more opaque than the overlay card so it reads as on top.
struct GlassMenu: View {
    let items: [GlassMenuItem]
    var opensUpward = false
    var presenter: GlassMenuPresenter?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.flatGlass) private var flatGlass

    private var shown: Bool { appeared || flatGlass }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items) { item in
                switch item.kind {
                case .row:
                    GlassMenuRow(item: item, isHovered: presenter?.hovered == item.id, isFocused: presenter?.focused == item.id) { presenter?.activate(item) }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: GlassMenuRowFrames.self, value: [item.id: geo.frame(in: .named("glass-menu"))])
                        })
                case .separator:
                    Rectangle().fill(Tokens.separator).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 5)
                        .accessibilityHidden(true)
                case .header:
                    Text(item.title.uppercased()).font(.system(size: 10.5, weight: .bold)).kerning(0.5)
                        .foregroundStyle(Tokens.labelTertiary)
                        .padding(EdgeInsets(top: 7, leading: 10, bottom: 4, trailing: 10))
                        .accessibilityAddTraits(.isHeader)
                case .custom(let view):
                    view.padding(EdgeInsets(top: 3, leading: 10, bottom: 4, trailing: 8))
                }
            }
        }
        .frame(minWidth: 190)
        .fixedSize()
        .padding(6)
        .modifier(GlassMenuSurface())
        .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: opensUpward ? .bottomTrailing : .topTrailing)
        .opacity(shown ? 1 : 0)
        .padding(GlassMenuPanel.margin)
        .coordinateSpace(name: "glass-menu")
        .onPreferenceChange(GlassMenuRowFrames.self) { frames in presenter?.frames = frames }
        .foregroundStyle(Tokens.label)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { appeared = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu")
    }
}

private struct GlassMenuSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatGlass) private var flatGlass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Group {
            if reduceTransparency || flatGlass {
                content.background(Tokens.glassOpaque, in: shape)
            } else {
                content
                    .background(scheme == .dark ? Color(white: 0.17).opacity(0.85) : Color.white.opacity(0.75), in: shape)
                    .glassEffect(.regular, in: shape)
            }
        }
        .overlay(shape.strokeBorder(contrast == .increased ? Tokens.label : Tokens.stroke, lineWidth: contrast == .increased ? 1 : 0.5))
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
    }
}

private struct GlassMenuRow: View {
    let item: GlassMenuItem
    let isHovered: Bool
    let isFocused: Bool
    let activate: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var titleColor: Color {
        if item.isDestructive { return Tokens.recording }
        return item.isSelected || item.isAccent ? Tokens.accentText : Tokens.label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: activate) {
            HStack(spacing: 10) {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.isSelected ? Tokens.onAccent : Tokens.labelSecondary)
                        .frame(width: 30, height: 30)
                        .background(item.isSelected ? Tokens.accent : Tokens.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    Circle().fill(item.isSelected ? Tokens.accent : .clear).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.isSelected ? .semibold : .regular, design: item.isMonospaced ? .monospaced : .default))
                        .foregroundStyle(titleColor)
                    if let detail = item.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Tokens.labelTertiary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 18)
                if item.isDisabled, let reason = item.disabledReason {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
                }
                if let keys = item.keys {
                    Text(keys).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(item.isDestructive ? Tokens.recording : Tokens.labelSecondary)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                }
            }
            .padding(EdgeInsets(top: 0, leading: item.symbol == nil ? 10 : 7, bottom: 0, trailing: 10))
            .frame(height: item.isTall ? 48 : 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: shape)
            .overlay { if isFocused { shape.strokeBorder(Tokens.accent, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(item.isDisabled ? 0.42 : 1)
        .allowsHitTesting(!item.isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isDisabled ? (item.disabledReason ?? "Unavailable") : (item.detail ?? ""))
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
    }

    private var fill: Color {
        if item.isSelected { return Tokens.accent.opacity(0.10) }
        if isHovered || isFocused { return Tokens.label.opacity(scheme == .dark ? 0.13 : 0.09) }
        return .clear
    }
}

// MARK: triggers

/// Remembers the AppKit view behind a trigger, so its menu can be placed against it on screen.
private final class GlassMenuAnchor {
    weak var view: NSView?
}

private struct GlassMenuAnchorReader: NSViewRepresentable {
    let anchor: GlassMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Any control that opens a glass menu. The label is told whether its menu is open, to draw itself as pressed.
struct GlassMenuButton<Label: View>: View {
    /// Menus opened from Murmur's windows take arrow keys; overlay menus are mouse only.
    var keyboard = true
    var endsWithTake = false
    let items: () -> [GlassMenuItem]
    @ViewBuilder let label: (_ isOpen: Bool) -> Label

    @State private var id = UUID().uuidString
    @State private var anchor = GlassMenuAnchor()

    var body: some View {
        Button {
            GlassMenuPresenter.shared.toggle(id: id, anchor: anchor.view, keyboard: keyboard, endsWithTake: endsWithTake, items: items())
        } label: {
            label(GlassMenuPresenter.shared.openID == id)
        }
        .buttonStyle(.plain)
        .background(GlassMenuAnchorReader(anchor: anchor))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens a menu")
    }
}

/// How a trigger looks while its menu is open: an accent tint and a 1.5 pt accent ring.
struct GlassMenuOpenHighlight<S: InsettableShape>: ViewModifier {
    let isOpen: Bool
    let shape: S
    func body(content: Content) -> some View {
        content
            .background { if isOpen { shape.fill(Tokens.accent.opacity(0.10)) } }
            .overlay { if isOpen { shape.strokeBorder(Tokens.accent, lineWidth: 1.5) } }
    }
}

/// A capsule pop-up button: the current value and a chevron, opening a glass menu of choices.
struct GlassPopUpButton<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 26
    var tint: Color = Tokens.label
    /// A second line for some or all choices.
    var details: [Value: String] = [:]
    var header: String?
    /// Extra rows after the choices, such as a link to System Settings.
    var footer: [GlassMenuItem] = []

    var body: some View {
        GlassMenuButton(items: { items }) { isOpen in
            PopLabel(text: options.first { $0.value == selection }?.label ?? "", height: height, tint: tint, isOpen: isOpen)
        }
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
    }

    private var items: [GlassMenuItem] {
        var items = header.map { [GlassMenuItem.header($0)] } ?? []
        items += options.map { option in
            GlassMenuItem(title: option.label, detail: details[option.value], isSelected: option.value == selection) { selection = option.value }
        }
        if !footer.isEmpty { items += [.separator] + footer }
        return items
    }
}

extension GlassPopUpButton where Value: CaseIterable & RawRepresentable, Value.RawValue == String, Value.AllCases: RandomAccessCollection {
    /// For enums whose raw value is the label.
    init(_ label: String, selection: Binding<Value>) {
        self.init(label: label, options: Value.allCases.map { ($0, $0.rawValue) }, selection: selection)
    }
}

struct PopLabel: View {
    let text: String
    var height: CGFloat = 26
    var tint: Color = Tokens.label
    var isOpen = false

    var body: some View {
        HStack(spacing: 7) {
            Text(text).font(.system(size: 12.5)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .foregroundStyle(tint)
        .padding(EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 8))
        .frame(height: height)
        .chipPill()
        .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Pill()))
        .contentShape(Pill())
    }
}
