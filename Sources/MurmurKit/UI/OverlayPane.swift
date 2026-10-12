import SwiftUI

/// What the preview card sits on. Drawn in code: no photos.
enum PreviewBackdrop: String, CaseIterable {
    case light, dark, busy

    var name: String { rawValue.capitalized }
    /// Text laid straight on the backdrop.
    var caption: Color { self == .light ? Color(nsColor: Tokens.rgba(28, 32, 44, 0.7)) : .white.opacity(0.85) }
}

struct PreviewBackdropView: View {
    let backdrop: PreviewBackdrop

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch backdrop {
                case .light:
                    color(0xEEF1F7)
                    blob(0xF8D0C0, x: 0.12, y: 0.18, in: geo.size)
                    blob(0xBDD7FF, x: 0.88, y: 0.14, in: geo.size)
                    blob(0xDACBFF, x: 0.62, y: 1, in: geo.size)
                    blob(0xCDEFE8, x: 0.38, y: 0.58, in: geo.size, reach: 0.4)
                case .dark:
                    color(0x0B0D1C)
                    blob(0x3F2C8E, x: 0.15, y: 0.2, in: geo.size)
                    blob(0x0C6E86, x: 0.88, y: 0.25, in: geo.size)
                    blob(0x6E2C5A, x: 0.55, y: 1, in: geo.size)
                case .busy:
                    LinearGradient(colors: [color(0x118AB2), color(0x8338EC), color(0xFF7A59)], startPoint: .leading, endPoint: .trailing)
                    blob(0xEF476F, x: 0.5, y: 0.9, in: geo.size)
                    blob(0x06D6A0, x: 0.7, y: 0.3, in: geo.size)
                    blob(0xFFD166, x: 0.2, y: 0.4, in: geo.size, reach: 0.4)
                    stripes
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ hex: UInt32) -> Color { Color(nsColor: Tokens.hex(hex)) }

    private func blob(_ hex: UInt32, x: CGFloat, y: CGFloat, in size: CGSize, reach: CGFloat = 0.55) -> some View {
        RadialGradient(colors: [color(hex), color(hex).opacity(0)], center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: max(size.width, size.height) * reach)
    }

    /// Thin slanted lines, the hardest thing to read text over.
    private var stripes: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height * 0.47, y: 0))
                x += 18
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 4)
        }
    }
}

/// The real card on a backdrop, fed a sample take. Nothing in it can be clicked or focused.
struct OverlayPreviewStage: View {
    let stores: Stores
    let backdrop: PreviewBackdrop
    var sample = OverlaySample.finished

    var body: some View {
        ZStack {
            PreviewBackdropView(backdrop: backdrop)
            OverlayView(stores: stores, sample: sample)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live preview of the overlay card with your current settings")
    }
}

/// The stage with its background picker. The sample types its sentence on a loop;
/// with Reduce Motion it shows the finished sentence and a still waveform.
private struct OverlayPreview: View {
    let stores: Stores
    @State private var backdrop = PreviewBackdrop.light
    @State private var sample = OverlaySample.finished
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.flatGlass) private var isSnapshot

    private var still: Bool { reduceMotion || isSnapshot }

    var body: some View {
        OverlayPreviewStage(stores: stores, backdrop: backdrop, sample: still ? .finished : sample)
            .overlay(alignment: .topTrailing) {
                SegmentedPicker(options: PreviewBackdrop.allCases.map { ($0, $0.name) }, selection: $backdrop, height: 22)
                    .frame(width: 168)
                    .background(Tokens.elevated.opacity(0.8), in: Pill())
                    .padding(10)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Preview background")
            }
            .overlay(alignment: .bottomLeading) {
                Text("Live preview · changes apply right away").font(.system(size: 11)).foregroundStyle(backdrop.caption)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 0))
                    .accessibilityHidden(true)
            }
            .task(id: still) {
                guard !still else { return }
                let letters = Array(OverlaySample.sentence)
                let tick = 0.09
                while !Task.isCancelled {
                    // Type the sentence, hold it for a moment, start again.
                    for step in 0...(letters.count + 18) {
                        var next = sample
                        next.text = String(letters.prefix(step))
                        next.elapsed = Int(Double(step) * tick)
                        next.levels.removeFirst()
                        let speaking = step < letters.count && letters[step] != " "
                        next.levels.append(speaking ? Float.random(in: 0.2...0.85) : 0)
                        sample = next
                        try? await Task.sleep(for: .seconds(tick))
                        if Task.isCancelled { return }
                    }
                }
            }
    }
}

/// A radio tile: a small picture on top, a name and one line under it.
private struct ChoiceTile<Picture: View>: View {
    let title: String
    let summary: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var picture: Picture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                picture
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.label)
                    Text(summary).font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 4)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 10, trailing: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Tokens.elevated, in: shape)
            .overlay(shape.strokeBorder(selected ? Tokens.accentText : Tokens.stroke, lineWidth: selected ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

struct OverlayPane: View {
    let stores: Stores
    @Environment(\.solidOverlay) private var solidOverlay

    private var settings: SettingsStore { stores.settings }
    private var overlay: OverlayAppearance { settings.overlay }
    private var reduceTransparency: Bool { DisplayOptions.shared.reduceTransparency || solidOverlay }

    private func bindOverlay<Value>(_ keyPath: WritableKeyPath<OverlayAppearance, Value>) -> Binding<Value> {
        Binding(get: { settings.overlay[keyPath: keyPath] }, set: { settings.overlay[keyPath: keyPath] = $0 })
    }

    var body: some View {
        OverlayPreview(stores: stores)
        material
        size
        SettingsGroup(title: "Show on the card") {
            SwitchRow(
                title: "Text line", subtitle: "“Listening…” and its hints. Words do not appear while you speak yet.",
                first: true, isOn: bindOverlay(\.showTranscript))
                .disabled(overlay.size == .compact).opacity(overlay.size == .compact ? 0.45 : 1)
            SwitchRow(title: "App it’s typing into", isOn: bindOverlay(\.showTargetApp))
                .disabled(overlay.size == .compact).opacity(overlay.size == .compact ? 0.45 : 1)
            SwitchRow(title: "Key hints", subtitle: "The esc and ↩ chips", isOn: bindOverlay(\.showKeyHints))
                .disabled(overlay.size == .compact).opacity(overlay.size == .compact ? 0.45 : 1)
            SwitchRow(title: "Timer", isOn: bindOverlay(\.showTimer))
        }
        placement
    }

    // MARK: material

    private var material: some View {
        let adjustable = overlay.materialIsAdjustable(reduceTransparency: reduceTransparency)
        let seeThrough = overlay.seeThroughIsAdjustable(reduceTransparency: reduceTransparency)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Material").font(.mmBodyEmphasis).foregroundStyle(Tokens.label).padding(.leading, 4)
            HStack(spacing: 8) {
                ForEach(OverlayAppearance.Material.allCases, id: \.self) { material in
                    ChoiceTile(title: material.name, summary: material.summary, selected: overlay.material == material) {
                        settings.overlay.material = material
                    } picture: {
                        ZStack {
                            PreviewBackdropView(backdrop: .busy)
                            swatch(material)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // To VoiceOver the tiles are one radio group.
            .accessibilityRepresentation {
                Picker("Material", selection: bindOverlay(\.material)) {
                    ForEach(OverlayAppearance.Material.allCases, id: \.self) { Text("\($0.name). \($0.summary)").tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            .disabled(!adjustable).opacity(adjustable ? 1 : 0.45)

            SettingsGroup {
                SettingsRow(
                    title: "See-through",
                    subtitle: seeThrough ? "How much of the desktop shows behind the card" : "Solid has no transparency",
                    showsDivider: false
                ) {
                    HStack(spacing: 10) {
                        Text("Clearer").fixedSize()
                        MurmurSlider(label: "See-through", value: bindOverlay(\.seeThrough), width: 130, valueText: "\(percent) percent")
                        Text("Frostier").fixedSize()
                        Text("\(percent)%").monospacedDigit().foregroundStyle(Tokens.labelSecondary).frame(width: 36, alignment: .trailing)
                    }
                    .font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                    .disabled(!seeThrough).opacity(seeThrough ? 1 : 0.45)
                }
                SettingsRow(title: "Card appearance", subtitle: "Only the card. Murmur’s windows keep their own.") {
                    SegmentedPicker(
                        options: [(.matchMac, "Match Mac"), (.light, "Light"), (.dark, "Dark")],
                        selection: bindOverlay(\.cardScheme), height: 26)
                        .frame(width: 234)
                }
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").font(.system(size: 12))
                    Text("When Reduce Transparency is on in macOS, the card is always Solid.").font(.mmCallout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(reduceTransparency ? Tokens.label : Tokens.labelTertiary)
                .padding(.horizontal, 14).frame(minHeight: 38)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
            }
            .padding(.top, 2)
        }
    }

    private var percent: Int { Int((overlay.seeThrough * 100).rounded()) }

    /// A little bar in that material, over the busy backdrop.
    private func swatch(_ material: OverlayAppearance.Material) -> some View {
        var look = overlay
        look.material = material
        return HStack(spacing: 6) {
            Circle().fill(Tokens.recording).frame(width: 6, height: 6)
            Pill().fill(Tokens.label.opacity(0.55)).frame(height: 3)
            Text("Aa").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.accentText)
        }
        .padding(.horizontal, 10)
        .frame(width: 118, height: 30)
        .modifier(OverlayMaterial(appearance: look, shape: Pill()))
        .accessibilityHidden(true)
    }

    // MARK: size

    private var size: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Size").font(.mmBodyEmphasis).foregroundStyle(Tokens.label).padding(.leading, 4)
            HStack(spacing: 8) {
                ForEach(OverlayAppearance.Size.allCases, id: \.self) { size in
                    ChoiceTile(title: size.name, summary: size.summary, selected: overlay.size == size) {
                        settings.overlay.size = size
                    } picture: {
                        ZStack {
                            Tokens.control
                            schematic(size)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityRepresentation {
                Picker("Size", selection: bindOverlay(\.size)) {
                    ForEach(OverlayAppearance.Size.allCases, id: \.self) { Text("\($0.name). \($0.summary)").tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
        }
    }

    private func schematic(_ size: OverlayAppearance.Size) -> some View {
        let box: (CGSize, CGFloat) = switch size {
        case .compact: (CGSize(width: 90, height: 16), 8)
        case .regular: (CGSize(width: 110, height: 40), 10)
        case .large: (CGSize(width: 130, height: 50), 12)
        }
        let shape = RoundedRectangle(cornerRadius: box.1, style: .continuous)
        return VStack(alignment: .leading, spacing: size == .large ? 6 : 4) {
            if size != .compact {
                Pill().fill(Tokens.labelTertiary).frame(width: box.0.width * (size == .large ? 0.64 : 0.56), height: size == .large ? 5 : 3)
                Pill().fill(Tokens.controlStrong).frame(width: box.0.width * 0.72, height: 3)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: box.0.width, height: box.0.height, alignment: .leading)
        .background(Tokens.elevated, in: shape)
        .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    // MARK: placement

    private var placement: some View {
        SettingsGroup(title: "Placement") {
            SettingsRow(title: "Position", subtitle: "Under the cursor follows the text you are typing. It falls back to the bottom when an app has no caret.", showsDivider: false) {
                GlassPopUpButton(
                    label: "Position", options: OverlayAppearance.Position.allCases.map { ($0, $0.name) },
                    selection: bindOverlay(\.position))
            }
            SettingsRow(
                title: "Distance from the edge",
                subtitle: overlay.usesEdgeDistance ? "From the Dock at the bottom, or from the menu bar at the top" : "Not used under the cursor: the card follows your text"
            ) {
                HStack(spacing: 10) {
                    MurmurSlider(
                        label: "Distance from the edge", value: bindOverlay(\.edgeDistance), range: OverlayAppearance.edgeDistanceRange,
                        step: 1, width: 170, valueText: "\(Int(overlay.edgeDistance)) points")
                    Text("\(Int(overlay.edgeDistance)) pt").font(.mmSub).monospacedDigit().foregroundStyle(Tokens.labelSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!overlay.usesEdgeDistance).opacity(overlay.usesEdgeDistance ? 1 : 0.45)
            }
            SettingsRow(title: "Display", subtitle: "With more than one screen") {
                GlassPopUpButton(
                    label: "Display", options: OverlayAppearance.Display.allCases.map { ($0, $0.name) },
                    selection: bindOverlay(\.display))
            }
        }
    }
}
