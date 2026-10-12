import AppKit
import SwiftUI

/// A made-up take for the preview in Settings › Overlay: the real card, fed sample words and levels.
struct OverlaySample: Equatable {
    static let sentence = "we’re shipping the beta on Friday and collecting feedback"
    static let target = TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes")

    var text = OverlaySample.sentence
    var levels: [Float] = (0..<DictationController.levelCount).map { i in
        let r = Float((i * 7919 + 13) % 100) / 100
        return r < 0.4 ? 0 : r * r * (0.3 + 0.7 * min(1, Float(i) / 34))
    }
    var elapsed = 4

    /// The whole sentence and a still waveform: what Reduce Motion and snapshots show.
    static let finished = OverlaySample()
}

/// The glass card that follows a take: listening, transcribing, inserted, or what went wrong.
/// It shows where the text is going and never takes focus.
struct OverlayView: View {
    let stores: Stores
    /// Set only by the preview in Settings: the card then shows this instead of a real take.
    var sample: OverlaySample? = nil
    @Environment(\.appActions) private var actions

    private var controller: DictationController { stores.controller }
    private var settings: SettingsStore { stores.settings }
    private var panels: OverlayPanelState { sample == nil ? stores.overlay : Self.previewPanels }
    private static let previewPanels = OverlayPanelState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var inherited
    @Environment(\.flatGlass) private var isSnapshot
    private var cleaning: Bool { destination != nil && controller.cleanupAvailability.isAvailable }
    private var destination: CleanupDestination? { sample == nil ? controller.cleanupDestination : nil }
    /// The cloud provider this take's text will go to, if any.
    private var cloudName: String? { destination?.cloudName }
    /// Why a take is staying on this Mac although a cloud provider is selected.
    private var stayingLocal: String? { if case .thisMac(let reason?) = destination { reason } else { nil } }

    private var state: DictationState { sample == nil ? controller.state : .recording(since: .distantPast) }
    private var target: TargetApp? { sample == nil ? controller.target : OverlaySample.target }
    private var levels: [Float] { sample?.levels ?? controller.levels }
    private var isSilent: Bool { sample == nil && controller.isSilent }
    private var deviceNotice: String? { sample == nil ? controller.deviceNotice : nil }

    private var appearance: OverlayAppearance { settings.overlay }
    /// A compact card has no room for a panel or a warning, so it opens up to the regular card while one shows.
    private var listeningCard: OverlayAppearance {
        var card = appearance
        if card.size == .compact, panels.open != nil || isSilent || deviceNotice != nil { card.size = .regular }
        return card
    }
    /// Cards that carry a message are never narrower than the regular card.
    private var messageWidth: CGFloat { max(appearance.size.cardWidth, OverlayAppearance.Size.regular.cardWidth) }
    private var scheme: ColorScheme {
        switch appearance.cardScheme {
        // A snapshot is drawn in the appearance it is asked for, not this Mac's.
        case .matchMac: isSnapshot ? inherited : (DisplayOptions.shared.systemIsDark ? .dark : .light)
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some View {
        Group {
            switch state {
            case .recording(let since): listening(since: since)
            case .processing: processing
            case .inserted(let summary): inserted(summary)
            case .error(.modelNotReady(let name, let progress)): modelCard(name: name, progress: progress)
            case .error(let error): errorCard(error)
            case .idle: EmptyView()
            }
        }
        .foregroundStyle(Tokens.label)
        // Only the card changes appearance; Murmur's windows keep their own.
        .environment(\.colorScheme, scheme)
        .id(settings.accent)
    }

    private func surface<S: InsettableShape>(_ shape: S) -> OverlayMaterial<S> { OverlayMaterial(appearance: appearance, shape: shape) }
    private func cardSurface(_ cornerRadius: CGFloat = Tokens.Radius.overlay) -> OverlayMaterial<RoundedRectangle> {
        surface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: listening

    private func listening(since: Date) -> some View {
        let card = listeningCard
        return Group {
            if card.size == .compact {
                compactListening(since: since, shown: card.elements)
            } else {
                fullListening(since: since, card: card)
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.frame(in: .global), initial: true) { _, frame in panels.cardFrame = frame }
        })
        // The height settles without a bounce. With Reduce Motion it does not animate: the body just crossfades.
        .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0), value: panels.open)
        .onChange(of: panels.open) { old, new in
            let name = (new ?? old) == .mode ? "Mode" : "Actions"
            AccessibilityNotification.Announcement("\(name), \(new == nil ? "collapsed" : "expanded")").post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Murmur is listening. Text will go into \(target?.name ?? "the front app").")
    }

    /// One row: the dot, the waveform, the timer and the mode.
    private func compactListening(since: Date, shown: OverlayAppearance.Elements) -> some View {
        HStack(spacing: 10) {
            PulseDot()
            Waveform(levels: levels)
            if shown.contains(.timer) { timer(since: since) }
            modePill
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 10))
        .frame(width: OverlayAppearance.Size.compact.cardWidth)
        .modifier(cardSurface(20))
    }

    private func fullListening(since: Date, card: OverlayAppearance) -> some View {
        let shown = card.elements
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if shown.contains(.targetApp) { targetLabel }
                destinationChip
                Spacer()
                modePill
                moreButton
            }
            .frame(height: 26)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))

            if let notice = deviceNotice {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.warning)
                    Text(notice).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 2, trailing: 10))
            }

            // Only the body swaps. The header and the footer stay, so the dot, the waveform and the timer keep saying "still recording".
            Group {
                switch panels.open {
                case .mode: modePanel
                case .actions: actionsPanel
                case nil: listeningBody(card)
                }
            }
            .transition(.opacity.animation(.easeOut(duration: reduceMotion ? 0.1 : 0.15)))
            // Reduce Motion: the animation is scoped to the body, so it crossfades while the card's height simply changes.
            .animation(reduceMotion ? .easeOut(duration: 0.1) : nil, value: panels.open)

            HStack(spacing: 10) {
                PulseDot(pulsing: !isSilent)
                Waveform(levels: levels, color: isSilent ? Tokens.warning : Tokens.label)
                if shown.contains(.timer) { timer(since: since) }
                if shown.contains(.keyHints) {
                    HStack(spacing: 4) {
                        hintKey("esc")
                        if sample != nil || settings.behavior == .toggle || controller.isLatched || settings.shortcut.isDoubleTap { hintKey("↩") }
                    }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 12))
        }
        .frame(width: card.size.cardWidth)
        .modifier(cardSurface())
    }

    @ViewBuilder private func timer(since: Date) -> some View {
        Group {
            if let sample { Text("0:\(String(format: "%02d", sample.elapsed))") } else { ElapsedTime(since: since) }
        }
        .font(.mmMono).foregroundStyle(Tokens.labelTertiary)
    }

    @ViewBuilder private func listeningBody(_ card: OverlayAppearance) -> some View {
        if isSilent {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash").font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.warning)
                VStack(alignment: .leading, spacing: 0) {
                    Text("No sound from microphone").font(.mmBodyEmphasis)
                    Text(AudioDevices.displayName(for: settings.microphoneID)).font(.mmSub).foregroundStyle(Tokens.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
        } else if !card.elements.contains(.transcript) {
            Color.clear.frame(height: 4)
        } else if let sample {
            // The whole sentence holds the height, so the card does not grow while the words arrive.
            Text(OverlaySample.sentence).hidden()
                .overlay(alignment: .topLeading) { Text(sample.text) }
                .font(.system(size: card.size.textSize)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Tokens.labelSecondary)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
        } else {
            Text(controller.isLatched || settings.shortcut.isDoubleTap ? "Listening… \(settings.shortcut.keycaps.joined(separator: " ")) again to insert" : "Listening…")
                .font(.system(size: card.size.textSize)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Tokens.labelSecondary)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
        }
    }

    // MARK: processing

    private var processing: some View {
        let status = HStack(spacing: 6) {
            Spinner(color: cloudName == nil ? Tokens.accentText : Tokens.warning)
            Text(cloudName.map { "Cleaning up with \($0)…" } ?? stayingLocal.map { "\($0) · cleaning up here…" } ?? (cleaning ? "Cleaning up…" : "Transcribing…"))
                .font(.mmSub).foregroundStyle(Tokens.labelTertiary).lineLimit(1)
        }
        return Group {
            if appearance.size == .compact {
                HStack(spacing: 10) {
                    status
                    Sweep().frame(height: 21)
                }
                .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                .frame(width: appearance.size.cardWidth)
                .modifier(cardSurface(20))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if appearance.showTargetApp { targetLabel }
                        Spacer()
                        status
                    }
                    .frame(height: 26)
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 14))
                    Sweep()
                        .frame(height: 21)
                        .padding(EdgeInsets(top: 10, leading: 16, bottom: 14, trailing: 16))
                }
                .frame(width: appearance.size.cardWidth)
                .modifier(cardSurface())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cloudName.map { "Transcribing, then cleaning up with \($0)" } ?? "Transcribing")
    }

    // MARK: inserted

    private func inserted(_ summary: InsertionSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.success)
                .frame(width: 30, height: 30).background(Tokens.successSoft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.copied ? "Copied to the clipboard" : "Inserted into \(summary.appName)").font(.system(size: 13.5, weight: .semibold))
                // The chosen provider did not do the clean-up: say what happened instead.
                if let note = summary.note { Text(note).font(.system(size: 11)).foregroundStyle(Tokens.warning) }
            }
            Text("\(summary.wordCount) \(summary.wordCount == 1 ? "word" : "words")").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            if !summary.copied, summary.note == nil {
                HStack(spacing: 4) {
                    hintKey("⌘Z")
                    Text("undo").font(.system(size: 10.5)).foregroundStyle(Tokens.labelTertiary)
                }
                .padding(.leading, 4)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        .frame(height: 46)
        .modifier(surface(Pill()))
        .accessibilityElement(children: .combine)
    }

    // MARK: error

    private func errorCard(_ error: DictationError) -> some View {
        let tint = error.isWarning ? Tokens.warning : Tokens.recording
        let soft = error.isWarning ? Tokens.warningSoft : Tokens.recordingSoft
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: error == .secureInput ? "lock.fill" : "exclamationmark")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 20, height: 20).background(soft, in: Circle())
                Text(error.title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    controller.dismissError()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                        .frame(width: 26, height: 26).chipPill()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))
            Text(error.message)
                .font(.mmBody).lineSpacing(4).foregroundStyle(Tokens.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
        }
        .frame(width: messageWidth)
        .modifier(cardSurface())
        .accessibilityElement(children: .combine)
    }

    // MARK: model not ready

    private func modelCard(name: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                targetLabel
                Spacer()
                dismissButton
            }
            .frame(height: 26)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text("Your model is still downloading").font(.system(size: 14, weight: .semibold))
                ProgressBar(value: progress)
                Text("\(name) · \(Int(progress * 100))%").font(.mmCallout).monospacedDigit().foregroundStyle(Tokens.labelTertiary)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
            HStack(spacing: 8) {
                Spacer()
                Button("Wait") { controller.dismissError() }.buttonStyle(MurmurButtonStyle(height: 30, fontSize: 12.5))
                Button("Choose Another Model") {
                    controller.dismissError()
                    actions.openSettings(.voiceEngine)
                }
                .buttonStyle(MurmurButtonStyle(kind: .primary, height: 30, fontSize: 12.5))
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        }
        .frame(width: messageWidth)
        .modifier(cardSurface())
    }

    // MARK: pieces

    private var modePill: some View {
        let isOpen = panels.open == .mode
        return Button {
            // From the actions panel this switches straight over: no close-then-open.
            panels.open = isOpen ? nil : .mode
        } label: {
            HStack(spacing: 4) {
                Text(settings.mode.label).font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(Tokens.accentText)
            .padding(EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 9))
            .frame(height: 26).chipPill()
            .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Pill()))
            .contentShape(Pill())
        }
        .buttonStyle(.plain).fixedSize()
        // The preview in Settings is a picture of the card: nothing in it takes keyboard focus.
        .focusable(sample == nil)
        .accessibilityLabel("Mode, \(settings.mode.label)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    /// ⋯ opens the actions for this take. While either panel is open it is a ✕ that closes it.
    private var moreButton: some View {
        let isOpen = panels.open != nil
        return Button {
            panels.open = isOpen ? nil : .actions
        } label: {
            Image(systemName: isOpen ? "xmark" : "ellipsis").font(.system(size: isOpen ? 9 : 11, weight: .bold))
                .foregroundStyle(panels.open == .actions ? Tokens.accentText : Tokens.labelSecondary)
                .frame(width: 26, height: 26).chipPill()
                .modifier(GlassMenuOpenHighlight(isOpen: panels.open == .actions, shape: Pill()))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).fixedSize()
        .focusable(sample == nil)
        .accessibilityLabel(isOpen ? "Close" : "More actions")
    }

    // MARK: panels

    private func eyebrow(_ title: String, _ rest: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).kerning(0.5)
            if let rest { Text(rest).font(.system(size: 11.5)) }
        }
        .foregroundStyle(Tokens.labelTertiary)
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 7, trailing: 16))
        .accessibilityHidden(true)
    }

    private func keyChip(_ keys: String, destructive: Bool = false) -> some View {
        Text(keys).font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(destructive ? Tokens.recording : Tokens.labelSecondary)
            .padding(.horizontal, 5).frame(minWidth: 18).frame(height: 18)
            .background(Tokens.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private func iconTile(_ symbol: String, selected: Bool = false, destructive: Bool = false) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? Tokens.recording : (selected ? Tokens.onAccent : Tokens.labelSecondary))
            .frame(width: 30, height: 30)
            .background(destructive ? .clear : (selected ? Tokens.accent : Tokens.controlStrong), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("Mode", "· applies to this take")
            HStack(spacing: 8) {
                ForEach(Array(DictationMode.offered.enumerated()), id: \.element) { index, mode in
                    modeTile(mode, keys: "⌥\(index + 1)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            // To VoiceOver the tiles are one radio group with the current mode selected.
            .accessibilityRepresentation {
                Picker("Mode", selection: Binding(get: { settings.mode }, set: { pick($0) })) {
                    ForEach(DictationMode.offered, id: \.self) { Text("\($0.label). \($0.summary)").tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            if settings.cleanupEnabled {
                // Changing the style leaves the panel open.
                HStack(spacing: 12) {
                    Text("Style").font(.system(size: 12)).foregroundStyle(Tokens.labelTertiary)
                    SegmentedPicker(
                        options: [CleanupPreset.lightTouch, .polished, .notes].map { ($0, $0.name) },
                        selection: bind(settings, \.cleanupPreset), height: 22)
                }
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 12))
            }
        }
        .padding(.bottom, 4)
    }

    private func modeTile(_ mode: DictationMode, keys: String) -> some View {
        let selected = settings.mode == mode
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { pick(mode) } label: {
            HStack(spacing: 10) {
                iconTile(mode.symbol, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? Tokens.accentText : Tokens.label)
                    Text(mode.summary).font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(selected ? Tokens.accent.opacity(0.10) : Tokens.chip, in: shape)
            .overlay(shape.strokeBorder(selected ? Tokens.accent : Tokens.stroke, lineWidth: selected ? 1.5 : 0.5))
            .overlay(alignment: .topTrailing) { keyChip(keys).padding(8) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    /// The choice shows as selected for a moment, then the panel collapses.
    private func pick(_ mode: DictationMode) {
        settings.mode = mode
        panels.collapseSoon()
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("This take")
            HStack(spacing: 8) {
                actionTile("Insert now", symbol: "arrow.right.to.line", keys: settings.hotkeyBindings.returnCommits || controller.isLatched ? "↩" : nil, spoken: "Return") {
                    panels.open = nil
                    controller.stopAndInsert()
                }
                actionTile("Copy instead", symbol: "doc.on.doc", keys: "⌘C", spoken: "Command C") {
                    panels.open = nil
                    controller.stopAndCopy()
                }
                // The only red on the card.
                actionTile("Cancel take", symbol: "xmark", keys: "esc", spoken: "Escape, twice", destructive: true) { controller.cancel() }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 4)
    }

    private func actionTile(_ title: String, symbol: String, keys: String?, spoken: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                iconTile(symbol, destructive: destructive)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(destructive ? Tokens.recording : Tokens.label).lineLimit(1)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(destructive ? Tokens.recordingSoft : Tokens.chip, in: shape)
            .overlay { if !destructive { shape.strokeBorder(Tokens.stroke, lineWidth: 0.5) } }
            .overlay(alignment: .topTrailing) { if let keys { keyChip(keys, destructive: destructive).padding(8) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(keys == nil ? "" : "Shortcut: \(spoken)")
    }

    private var dismissButton: some View {
        Button {
            controller.dismissError()
        } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                .frame(width: 26, height: 26).chipPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    /// Where this take's text is going for clean-up, whenever that is not simply "this Mac, as always".
    @ViewBuilder private var destinationChip: some View {
        switch destination {
        case .cloud(let name):
            HStack(spacing: 4) {
                Image(systemName: "cloud").font(.system(size: 9, weight: .bold))
                Text("via \(name)").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Tokens.warning)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Tokens.warningSoft, in: Pill())
            .accessibilityLabel("Clean-up text will be sent to \(name)")
        case .thisMac(let reason?):
            // A cloud provider is selected, but this take stays here. The reason is said while it is cleaned up.
            PlaceBadge(isLocal: true)
                .help(reason)
                .accessibilityLabel("Cleaned up on this Mac. \(reason)")
        default:
            EmptyView()
        }
    }

    private var targetLabel: some View {
        HStack(spacing: 7) {
            if let icon = target?.bundleIdentifier.flatMap({ AppIcons.icon(forBundleIdentifier: $0) }) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "text.cursor").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelSecondary).frame(width: 18, height: 18)
            }
            Text(target?.name ?? "Front app").font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
        }
    }

    private func hintKey(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Tokens.labelSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .chipSurface(cornerRadius: 6)
    }
}

/// An accent band sweeping across while the transcript is on its way. Still under Reduce Motion.
private struct Sweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4).fill(Tokens.control)
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [.clear, Tokens.accentSoft, Tokens.accent.opacity(0.35), Tokens.accentSoft, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: reduceMotion ? geo.size.width * 0.35 : (moving ? geo.size.width : -geo.size.width * 0.3))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: 6)
                .frame(maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { moving = true }
        }
        .accessibilityHidden(true)
    }
}
