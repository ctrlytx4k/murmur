import AppKit
import Observation

/// How the overlay card looks and where it sits. Settings › Overlay edits this; the card reads it live.
public nonisolated struct OverlayAppearance: Codable, Equatable, Sendable {
    public enum Material: String, Codable, CaseIterable, Sendable {
        case glass, frosted, solid, tinted

        public var name: String {
            switch self {
            case .glass: "Glass"
            case .frosted: "Frosted"
            case .solid: "Solid"
            case .tinted: "Tinted"
            }
        }

        public var summary: String {
            switch self {
            case .glass: "Your desktop shows through"
            case .frosted: "Easier to read on busy wallpapers"
            case .solid: "No transparency, most contrast"
            case .tinted: "Glass with a touch of accent"
            }
        }
    }

    public enum CardScheme: String, Codable, CaseIterable, Sendable { case matchMac, light, dark }

    public enum Size: String, Codable, CaseIterable, Sendable {
        case compact, regular, large

        public var name: String {
            switch self {
            case .compact: "Compact"
            case .regular: "Regular"
            case .large: "Large"
            }
        }

        public var summary: String {
            switch self {
            case .compact: "Waveform and mode only, no text"
            case .regular: "The card with its text line"
            case .large: "Bigger text, easier to read"
            }
        }

        public var cardWidth: Double {
            switch self {
            case .compact: 300
            case .regular: 400
            case .large: 480
            }
        }

        public var textSize: Double { self == .large ? 18 : 15 }
    }

    public enum Position: String, Codable, CaseIterable, Sendable {
        case underCursor, bottom, top

        public var name: String {
            switch self {
            case .underCursor: "Under the cursor"
            case .bottom: "Bottom of screen"
            case .top: "Top of screen"
            }
        }
    }

    public enum Display: String, Codable, CaseIterable, Sendable {
        case cursorScreen, mainScreen

        public var name: String { self == .cursorScreen ? "The one with the cursor" : "Main display" }
    }

    /// What a listening card can show. Which of them it does show depends on the size and the switches.
    public struct Elements: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let header = Elements(rawValue: 1 << 0)
        public static let targetApp = Elements(rawValue: 1 << 1)
        public static let transcript = Elements(rawValue: 1 << 2)
        public static let waveform = Elements(rawValue: 1 << 3)
        public static let timer = Elements(rawValue: 1 << 4)
        public static let keyHints = Elements(rawValue: 1 << 5)
        public static let modePill = Elements(rawValue: 1 << 6)
    }

    public static let edgeDistanceRange = 24.0...160.0

    public var material = Material.glass
    /// 0 is clearer, 1 is frostier.
    public var seeThrough = 0.35
    public var cardScheme = CardScheme.matchMac
    public var size = Size.regular
    public var showTranscript = true
    public var showTargetApp = true
    public var showKeyHints = true
    public var showTimer = true
    public var position = Position.bottom
    /// Points from the screen edge. Only used at the bottom and the top.
    public var edgeDistance = 64.0
    public var display = Display.cursorScreen

    public init() {}

    // A value missing or unknown in a saved copy falls back to its default, so older and newer builds can share one.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func raw<T: RawRepresentable>(_ key: CodingKeys, _ fallback: T) -> T where T.RawValue == String {
            (try? box.decode(String.self, forKey: key)).flatMap(T.init(rawValue:)) ?? fallback
        }
        func bool(_ key: CodingKeys) -> Bool { (try? box.decode(Bool.self, forKey: key)) ?? true }
        material = raw(.material, material)
        seeThrough = (try? box.decode(Double.self, forKey: .seeThrough)) ?? seeThrough
        cardScheme = raw(.cardScheme, cardScheme)
        size = raw(.size, size)
        showTranscript = bool(.showTranscript)
        showTargetApp = bool(.showTargetApp)
        showKeyHints = bool(.showKeyHints)
        showTimer = bool(.showTimer)
        position = raw(.position, position)
        edgeDistance = (try? box.decode(Double.self, forKey: .edgeDistance)) ?? edgeDistance
        display = raw(.display, display)
        self = clamped
    }

    /// The same settings with the two sliders inside their ranges.
    public var clamped: OverlayAppearance {
        var copy = self
        copy.seeThrough = seeThrough.isFinite ? min(max(seeThrough, 0), 1) : 0.35
        copy.edgeDistance = edgeDistance.isFinite ? min(max(edgeDistance, Self.edgeDistanceRange.lowerBound), Self.edgeDistanceRange.upperBound) : 64
        return copy
    }

    // MARK: what the card does with them

    /// Reduce Transparency in macOS always wins: the card is solid.
    public func effectiveMaterial(reduceTransparency: Bool) -> Material {
        reduceTransparency ? .solid : material
    }

    /// Whether the Material tiles can be changed right now.
    public func materialIsAdjustable(reduceTransparency: Bool) -> Bool { !reduceTransparency }

    /// Whether the See-through slider does anything right now.
    public func seeThroughIsAdjustable(reduceTransparency: Bool) -> Bool {
        effectiveMaterial(reduceTransparency: reduceTransparency) != .solid
    }

    /// Opacity of the fill laid over the glass, by material.
    public var fillOpacity: Double {
        let amount = clamped.seeThrough
        switch material {
        // Wide ranges, so the slider is plain to see: glass goes from none to mostly frosted, frosted from half to nearly solid.
        case .glass, .tinted: return 0.7 * amount
        case .frosted: return 0.5 + 0.45 * amount
        case .solid: return 1
        }
    }

    /// Whether the distance slider is used: under the cursor the card follows the text instead.
    public var usesEdgeDistance: Bool { position != .underCursor }

    /// Compact is one row with no header and no text, whatever the transcript switch says.
    public var elements: Elements {
        var shown: Elements = [.waveform, .modePill]
        if showTimer { shown.insert(.timer) }
        guard size != .compact else { return shown }
        shown.insert(.header)
        if showTargetApp { shown.insert(.targetApp) }
        if showTranscript { shown.insert(.transcript) }
        if showKeyHints { shown.insert(.keyHints) }
        return shown
    }
}

/// The macOS display options the card has to follow, kept current while the app runs.
@Observable
public final class DisplayOptions {
    public static let shared = DisplayOptions()

    public private(set) var reduceTransparency: Bool
    /// Whether macOS itself is in Dark Mode, whatever appearance Murmur's own windows use.
    public private(set) var systemIsDark: Bool

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        reduceTransparency = Self.readReduceTransparency()
        systemIsDark = Self.readSystemIsDark()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    private func refresh() {
        let reduce = Self.readReduceTransparency(), dark = Self.readSystemIsDark()
        if reduce != reduceTransparency { reduceTransparency = reduce }
        if dark != systemIsDark { systemIsDark = dark }
    }

    private static func readReduceTransparency() -> Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    private static func readSystemIsDark() -> Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
}
