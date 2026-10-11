import AppKit

/// What the menu bar item shows. Status color is the only non-template pixel.
public nonisolated enum MenuBarState: Equatable, Sendable {
    case idle, recording, processing, needsAttention, permissionMissing

    var accessibilityLabel: String {
        switch self {
        case .idle: "Murmur, ready"
        case .recording: "Murmur, recording"
        case .processing: "Murmur, transcribing"
        case .needsAttention: "Murmur, needs attention"
        case .permissionMissing: "Murmur, permission missing"
        }
    }
}

/// Draws the 18 pt "Soft wave" glyph for each state. `phase` runs 0..<1 for the animated states.
nonisolated enum StatusIcon {
    static let recordingRed = NSColor(srgbRed: 0.85, green: 0.18, blue: 0.13, alpha: 1)
    static let attentionAmber = NSColor(srgbRed: 0.90, green: 0.55, blue: 0.05, alpha: 1)

    static func image(for state: MenuBarState, phase: CGFloat = 0) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let s = rect.width / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            func wave(halfPeriods: Int) -> NSBezierPath {
                let path = NSBezierPath()
                path.move(to: pt(6, 12))
                for i in 0..<halfPeriods {
                    let x = 6 + CGFloat(i) * 3
                    // Quadratic segment, raised to the cubic NSBezierPath wants.
                    let from = pt(x, 12), to = pt(x + 3, 12), c = pt(x + 1.5, i.isMultiple(of: 2) ? 8.8 : 15.2)
                    path.curve(to: to,
                               controlPoint1: NSPoint(x: from.x + (c.x - from.x) * 2 / 3, y: from.y + (c.y - from.y) * 2 / 3),
                               controlPoint2: NSPoint(x: to.x + (c.x - to.x) * 2 / 3, y: to.y + (c.y - to.y) * 2 / 3))
                }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                return path
            }
            func circle(radius: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: (12 - radius) * s, y: (12 - radius) * s, width: radius * 2 * s, height: radius * 2 * s))
            }
            let line = 1.9 * s

            switch state {
            case .idle:
                NSColor.black.setStroke()
                let ring = circle(radius: 8.5); ring.lineWidth = line; ring.stroke()
                let w = wave(halfPeriods: 4); w.lineWidth = line; w.stroke()

            case .recording:
                // Soft pulse: a ring that swells past the disc and fades.
                if phase > 0 {
                    recordingRed.withAlphaComponent(0.7 * (1 - phase)).setFill()
                    circle(radius: 9.4 * (0.8 + 0.45 * phase)).fill()
                }
                recordingRed.setFill()
                circle(radius: 9.4).fill()
                NSColor.white.setStroke()
                let w = wave(halfPeriods: 4); w.lineWidth = 2 * s; w.stroke()

            case .processing:
                NSColor.black.setStroke()
                let ring = circle(radius: 8.5); ring.lineWidth = line; ring.stroke()
                let w = wave(halfPeriods: 4); w.lineWidth = line
                // The wave flows: dashes travel along it.
                let dash: [CGFloat] = [3 * s, 2.4 * s]
                w.setLineDash(dash, count: 2, phase: phase * 5.4 * s)
                w.stroke()

            case .needsAttention:
                NSColor.labelColor.setStroke()
                let ring = circle(radius: 8.5); ring.lineWidth = line; ring.stroke()
                let w = wave(halfPeriods: 2); w.lineWidth = line; w.stroke()
                // Cut the badge's footprint out of the glyph, then draw the badge.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: NSRect(x: 11.6 * s, y: 11.6 * s, width: 12.8 * s, height: 12.8 * s)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                attentionAmber.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13 * s, y: 13 * s, width: 10 * s, height: 10 * s)).fill()
                NSColor.white.setStroke()
                let mark = NSBezierPath()
                mark.move(to: pt(18, 15.6)); mark.line(to: pt(18, 18.2))
                mark.move(to: pt(18, 20.3)); mark.line(to: pt(18, 20.31))
                mark.lineWidth = line; mark.lineCapStyle = .round; mark.stroke()

            case .permissionMissing:
                NSColor.black.withAlphaComponent(0.4).setStroke()
                let ring = circle(radius: 8.5); ring.lineWidth = line; ring.stroke()
                let w = wave(halfPeriods: 4); w.lineWidth = line; w.stroke()
                NSColor.black.setStroke()
                let slash = NSBezierPath()
                slash.move(to: pt(4.5, 4.5)); slash.line(to: pt(19.5, 19.5))
                slash.lineWidth = line; slash.lineCapStyle = .round; slash.stroke()
            }
            return true
        }
        image.isTemplate = state == .idle || state == .processing || state == .permissionMissing
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }
}
