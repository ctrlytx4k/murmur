import SwiftUI

// Written out by hand: the @Entry macro needs a compiler plugin that only ships with Xcode.
private struct FlatGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draw glass as its opaque tint. Set for offscreen snapshots, where there is nothing behind the view to refract.
    var flatGlass: Bool {
        get { self[FlatGlassKey.self] }
        set { self[FlatGlassKey.self] = newValue }
    }
}

/// Liquid Glass for floating surfaces only: overlay, dropdown, sidebar, alerts.
/// Reduce Transparency swaps it for the opaque tint; Increase Contrast adds a 1 pt label-color border.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.flatGlass) private var flatGlass

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || flatGlass {
                content
                    .background(Tokens.glassOpaque, in: shape)
                    .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
        .overlay {
            if contrast == .increased { shape.strokeBorder(Tokens.label, lineWidth: 1) }
        }
    }
}

/// The translucent fill used for secondary controls that sit on glass or on a window.
struct ChipSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Tokens.chip, in: shape)
            .overlay(shape.strokeBorder(contrast == .increased ? Tokens.label : Tokens.stroke, lineWidth: contrast == .increased ? 1 : 0.5))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func glassPill() -> some View { modifier(GlassSurface(shape: Pill())) }

    func chipSurface(cornerRadius: CGFloat) -> some View {
        modifier(ChipSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func chipPill() -> some View { modifier(ChipSurface(shape: Pill())) }
}
