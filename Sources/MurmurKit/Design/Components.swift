import SwiftUI

// MARK: buttons

/// Capsule buttons. One primary per surface; everything else is a glass chip.
struct MurmurButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, recording }
    var kind: Kind = .secondary
    var height: CGFloat = 30
    var fontSize: CGFloat = 13
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let filled = kind == .primary || kind == .recording
        let fill = kind == .recording ? Tokens.recording : Tokens.accent
        configuration.label
            .font(.system(size: fontSize, weight: filled ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, fullWidth ? 8 : height * 0.47)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background {
                if filled {
                    Pill().fill(fill)
                    // Top sheen.
                    Pill().fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)))
                    Pill().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
            }
            .modifier(ConditionalChip(enabled: !filled))
            .shadow(color: filled ? fill.opacity(0.22) : .clear, radius: 6, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Pill())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Tokens.onAccent
        case .recording: .white
        case .danger: Tokens.recording
        case .secondary: Tokens.label
        }
    }
}

private struct ConditionalChip: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.chipPill() } else { content }
    }
}

/// Text-only button in the accent text color.
struct LinkButtonStyle: ButtonStyle {
    var color: Color = Tokens.accentText
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A plain row that highlights on hover, for menu-like lists inside glass panels.
struct HoverRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration, cornerRadius: cornerRadius) }

    private struct Row: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? Tokens.control : .clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: toggle

struct MurmurToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Pill()
                .fill(configuration.isOn ? Tokens.accent : Tokens.controlStrong)
                .overlay(Pill().strokeBorder(Tokens.stroke, lineWidth: 0.5))
                .frame(width: 42, height: 26)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(LinearGradient(colors: [.white, Color(red: 0.93, green: 0.94, blue: 0.96)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .padding(2)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

// MARK: segmented control

struct SegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Tokens.label : Tokens.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .modifier(ConditionalChip(enabled: on))
                        .contentShape(Pill())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Tokens.control, in: Pill())
    }
}

// MARK: small pieces

struct Keycap: View {
    let text: String
    var size: CGFloat = 22
    var background: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.55, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minWidth: size, minHeight: size)
            .frame(height: size)
            .modifier(KeycapSurface(background: background))
    }

    private struct KeycapSurface: ViewModifier {
        let background: Color?
        func body(content: Content) -> some View {
            if let background {
                content.background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.keycap, style: .continuous))
            } else {
                content.chipSurface(cornerRadius: Tokens.Radius.keycap)
            }
        }
    }
}

/// A status dot with the 1.2 s recording pulse. Reduce Motion keeps the dot and drops the pulse.
struct PulseDot: View {
    var color: Color = Tokens.recording
    var size: CGFloat = 7
    var pulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                Circle().fill(color)
                    .scaleEffect(expanded ? 2.2 : 0.7)
                    .opacity(expanded ? 0 : 0.75)
                    .onAppear {
                        withAnimation(.easeOut(duration: Tokens.Motion.pulse).repeatForever(autoreverses: false)) { expanded = true }
                    }
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Spinner: View {
    var size: CGFloat = 10
    var color: Color = Tokens.accentText
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.6, size / 9), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}

/// Live level bars: 1.5 pt wide, 2 pt apart. Quiet samples collapse to a dim dot.
struct Waveform: View {
    let levels: [Float]
    var maxHeight: CGFloat = 24
    var color: Color = Tokens.label

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                let quiet = level < 0.06
                Pill()
                    .fill(color.opacity(quiet ? 0.45 : 0.95))
                    .frame(width: 1.5, height: quiet ? 1.5 : max(3, CGFloat(level) * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .accessibilityHidden(true)
    }
}

struct StatusChip: View {
    let text: String
    var symbol: String? = nil
    let color: Color
    let background: Color

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(background, in: Pill())
    }
}

// MARK: grouped rows (solid content, never glass)

struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.mmBodyEmphasis).foregroundStyle(Tokens.label).padding(.leading, 4)
            }
            // Dividers between rows come from the rows themselves, see SettingsRow.
            VStack(spacing: 0) { content }
                .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = Tokens.labelTertiary
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mmBody).foregroundStyle(Tokens.label)
                if let subtitle {
                    Text(subtitle).font(.mmSub).foregroundStyle(subtitleColor).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 48)
        .overlay(alignment: .top) {
            if showsDivider { Rectangle().fill(Tokens.separator).frame(height: 1) }
        }
    }
}
