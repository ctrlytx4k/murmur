import SwiftUI

/// The "Soft wave" mark on its 24 pt construction grid: a circle of radius 8.5
/// and a wave running 6 -> 18 in four 3 pt half-periods.
nonisolated enum MarkGeometry {
    static func wave(in rect: CGRect, from start: CGFloat = 6, halfPeriods: Int = 4) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(start, 12))
        for i in 0..<halfPeriods {
            let x = start + CGFloat(i) * 3
            path.addQuadCurve(to: p(x + 3, 12), control: p(x + 1.5, i.isMultiple(of: 2) ? 8.8 : 15.2))
        }
        return path
    }

    static func circle(in rect: CGRect, radius: CGFloat = 8.5) -> Path {
        let s = min(rect.width, rect.height) / 24
        return Path(ellipseIn: CGRect(x: rect.midX - radius * s, y: rect.midY - radius * s, width: radius * 2 * s, height: radius * 2 * s))
    }
}

nonisolated struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path { MarkGeometry.wave(in: rect) }
}

nonisolated struct MarkCircleShape: Shape {
    func path(in rect: CGRect) -> Path { MarkGeometry.circle(in: rect) }
}

/// The app icon tile: pale gradient, ink circle, accent wave, top-left sheen.
struct AppIconTile: View {
    var size: CGFloat = 38

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        let stroke = StrokeStyle(lineWidth: size * 0.68 / 24 * 1.8, lineCap: .round, lineJoin: .round)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(red: 0.99, green: 1, blue: 1), Color(red: 0.79, green: 0.82, blue: 0.89)], startPoint: .topLeading, endPoint: .bottomTrailing))
            ZStack {
                MarkCircleShape().stroke(Color(red: 0.11, green: 0.12, blue: 0.16), style: stroke)
                // The wave stays Ice blue in both appearances: the tile is always light.
                WaveShape().stroke(Color(red: 0.04, green: 0.39, blue: 0.85), style: stroke)
            }
            .frame(width: size * 0.68, height: size * 0.68)
            shape.fill(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)], startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.6)))
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.31).opacity(0.18), radius: size * 0.1, y: size * 0.08)
        .accessibilityHidden(true)
    }
}
