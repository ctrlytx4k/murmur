import SwiftUI

/// Solid text field: 30 pt tall, 10 pt corners, accent ring when focused or flagged.
struct FieldChrome: ViewModifier {
    var emphasized = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.mmBody)
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(emphasized ? Tokens.accentText : Tokens.stroke, lineWidth: emphasized ? 2 : 0.5))
    }
}

extension View {
    func fieldChrome(emphasized: Bool = false) -> some View { modifier(FieldChrome(emphasized: emphasized)) }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .chipPill()
    }
}

/// Five small bars: how fast or how accurate, relative to the other models.
struct MeterDots: View {
    let filled: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(i < filled ? Tokens.accent : Tokens.controlStrong).frame(width: 10, height: 4)
            }
        }
        .accessibilityLabel("\(filled) of 5")
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            Pill().fill(Tokens.controlStrong)
                .overlay(alignment: .leading) { Pill().fill(Tokens.accent).frame(width: geo.size.width * min(max(value, 0), 1)) }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// The 180 pt track with a wide capsule thumb.
struct ThresholdSlider: View {
    @Binding var value: Double
    var body: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 26
            let x = (geo.size.width - thumb) * value
            ZStack(alignment: .leading) {
                Pill().fill(Tokens.controlStrong).frame(height: 6)
                Pill().fill(Tokens.accent).frame(width: x + thumb / 2, height: 6)
                Pill().fill(LinearGradient(colors: [.white, Color(red: 0.93, green: 0.94, blue: 0.96)], startPoint: .top, endPoint: .bottom))
                    .frame(width: thumb, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = min(max((drag.location.x - thumb / 2) / (geo.size.width - thumb), 0), 1)
            })
        }
        .frame(width: 180, height: 24)
        .accessibilityRepresentation { Slider(value: $value) }
    }
}

struct ModeTag: View {
    let mode: DictationMode
    var body: some View {
        let colors: (Color, Color) = switch mode {
        case .cleaned: (Tokens.accentSoft, Tokens.accentText)
        case .raw: (Tokens.controlStrong, Tokens.labelSecondary)
        case .command: (Tokens.commandSoft, Tokens.command)
        }
        Text(mode.shortLabel.uppercased())
            .font(.system(size: 9.5, weight: .bold)).kerning(0.4)
            .foregroundStyle(colors.1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(colors.0, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A round icon-only button, for row actions.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = Tokens.labelTertiary
    var chip = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .modifier(OptionalChip(on: chip))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private struct OptionalChip: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.chipPill() } else { content }
        }
    }
}

/// Five green bars for the microphone in use. Only shows during a take: that is the only time
/// Murmur listens, so it is the only time there is a level to show.
struct ActiveMicMeter: View {
    let controller: DictationController

    var body: some View {
        if controller.state.isRecording {
            let lit = Int((Double(controller.levels.last ?? 0) * 5).rounded(.up))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<5, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1).fill(bar < lit ? Tokens.success : Tokens.controlStrong)
                        .frame(width: 3, height: CGFloat(4 + bar * 2))
                }
            }
            .frame(height: 12)
            .accessibilityLabel("Input level \(lit) of 5")
        }
    }
}
