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

private struct SolidOverlayKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Behave as if Reduce Transparency were on in macOS. Set for snapshots of that state.
    var solidOverlay: Bool {
        get { self[SolidOverlayKey.self] }
        set { self[SolidOverlayKey.self] = newValue }
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

/// The overlay card's surface, in the material chosen in Settings › Overlay.
/// Reduce Transparency always gets Solid, and follows the macOS switch while the card is up.
struct OverlayMaterial<S: InsettableShape>: ViewModifier {
    let appearance: OverlayAppearance
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.flatGlass) private var flatGlass
    @Environment(\.solidOverlay) private var solidOverlay

    func body(content: Content) -> some View {
        let material = appearance.effectiveMaterial(reduceTransparency: DisplayOptions.shared.reduceTransparency || solidOverlay)
        Group {
            if material == .solid {
                content
                    .background(Tokens.windowBackground, in: shape)
                    .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
            } else {
                let filled = content.background {
                    // The fill sits on the glass: the more of it, the less of the desktop comes through.
                    shape.fill((material == .frosted ? Tokens.windowBackground : Tokens.glassOpaque).opacity(appearance.fillOpacity))
                    if material == .tinted {
                        shape.fill(Tokens.accent.opacity(0.12))
                        shape.strokeBorder(Tokens.accentSoft, lineWidth: 1)
                    }
                }
                if flatGlass {
                    // Offscreen there is no blur. A thin veil stands in for the glass so the fill still reads.
                    filled
                        .background(Tokens.glassOpaque.opacity(0.5), in: shape)
                        .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
                } else if material == .tinted {
                    filled.glassEffect(.regular.tint(Tokens.accent.opacity(0.2)), in: shape)
                } else {
                    filled.glassEffect(.regular, in: shape)
                }
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
