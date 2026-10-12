import Foundation
import Testing
@testable import MurmurKit

@MainActor
@Suite struct OverlayAppearanceTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")! }

    @Test func aFreshInstallGetsTheDocumentedDefaults() {
        let overlay = SettingsStore(defaults: defaults()).overlay
        #expect(overlay.material == .glass && overlay.seeThrough == 0.35 && overlay.cardScheme == .matchMac)
        #expect(overlay.size == .regular)
        #expect(overlay.showTranscript && overlay.showTargetApp && overlay.showKeyHints && overlay.showTimer)
        #expect(overlay.position == .bottom && overlay.edgeDistance == 64 && overlay.display == .cursorScreen)
        Accent.current = .ice
    }

    // MARK: migration

    @Test func thePositionMovesOverFromGeneralExactlyOnce() {
        let d = defaults()
        d.set("Top of screen", forKey: "overlayPosition")
        let first = SettingsStore(defaults: d)
        #expect(first.overlay.position == .top)
        // Everything else starts at its default, and the old key is gone.
        var expected = OverlayAppearance()
        expected.position = .top
        #expect(first.overlay == expected)
        #expect(d.object(forKey: "overlayPosition") == nil)

        // The user then picks something else. An old value turning up again must not undo that.
        first.overlay.position = .underCursor
        d.set("Top of screen", forKey: "overlayPosition")
        let second = SettingsStore(defaults: d)
        #expect(second.overlay.position == .underCursor)
        Accent.current = .ice
    }

    @Test func aBottomOrUnknownOldPositionBecomesBottom() {
        for old in ["Bottom of screen", "Near text cursor"] {
            let d = defaults()
            d.set(old, forKey: "overlayPosition")
            #expect(SettingsStore(defaults: d).overlay.position == .bottom)
            #expect(d.object(forKey: "overlayPosition") == nil)
        }
        Accent.current = .ice
    }

    @Test func overlaySettingsSurviveARelaunchAndResetOnlyThemselves() {
        let d = defaults()
        let settings = SettingsStore(defaults: d)
        settings.language = "German"
        settings.overlay.material = .frosted
        settings.overlay.seeThrough = 0.8
        settings.overlay.cardScheme = .dark
        settings.overlay.size = .large
        settings.overlay.showTimer = false
        settings.overlay.position = .top
        settings.overlay.edgeDistance = 120
        settings.overlay.display = .mainScreen
        let reopened = SettingsStore(defaults: d)
        #expect(reopened.overlay == settings.overlay && reopened.overlay.size == .large && reopened.overlay.edgeDistance == 120)

        // What the pane's Reset to Defaults does.
        reopened.overlay = OverlayAppearance()
        #expect(SettingsStore(defaults: d).overlay == OverlayAppearance())
        #expect(SettingsStore(defaults: d).language == "German")
        Accent.current = .ice
    }

    @Test func slidersStayInsideTheirRanges() {
        let settings = SettingsStore(defaults: defaults())
        settings.overlay.seeThrough = 4
        settings.overlay.edgeDistance = 2
        #expect(settings.overlay.seeThrough == 1 && settings.overlay.edgeDistance == 24)
        settings.overlay.edgeDistance = 900
        #expect(settings.overlay.edgeDistance == 160)
        Accent.current = .ice
    }

    @Test func aSavedCopyWithMissingOrUnknownValuesStillLoads() throws {
        let data = Data(#"{"material":"holographic","size":"large","edgeDistance":500}"#.utf8)
        let overlay = try JSONDecoder().decode(OverlayAppearance.self, from: data)
        #expect(overlay.material == .glass && overlay.size == .large && overlay.edgeDistance == 160)
        #expect(overlay.showTranscript && overlay.position == .bottom)
    }

    // MARK: Reduce Transparency

    @Test func reduceTransparencyForcesSolidAndDisablesTheControls() {
        for material in OverlayAppearance.Material.allCases {
            var overlay = OverlayAppearance()
            overlay.material = material
            #expect(overlay.effectiveMaterial(reduceTransparency: true) == .solid)
            #expect(!overlay.materialIsAdjustable(reduceTransparency: true))
            #expect(!overlay.seeThroughIsAdjustable(reduceTransparency: true))
            // Off again: the choice is back untouched, and so are the controls.
            #expect(overlay.effectiveMaterial(reduceTransparency: false) == material)
            #expect(overlay.materialIsAdjustable(reduceTransparency: false))
            #expect(overlay.seeThroughIsAdjustable(reduceTransparency: false) == (material != .solid))
        }
    }

    @Test func seeThroughSetsTheFillWithinEachMaterialsRange() {
        var overlay = OverlayAppearance()
        overlay.seeThrough = 0
        #expect(overlay.fillOpacity == 0)
        overlay.seeThrough = 1
        #expect(abs(overlay.fillOpacity - 0.6) < 0.0001)
        overlay.material = .frosted
        #expect(abs(overlay.fillOpacity - 0.92) < 0.0001)
        overlay.seeThrough = 0
        #expect(abs(overlay.fillOpacity - 0.75) < 0.0001)
        overlay.material = .solid
        #expect(overlay.fillOpacity == 1)
    }

    // MARK: sizes

    @Test func regularAndLargeShowEverythingAndEachSwitchHidesItsOwnElement() {
        for size in [OverlayAppearance.Size.regular, .large] {
            var overlay = OverlayAppearance()
            overlay.size = size
            #expect(overlay.elements == [.header, .targetApp, .transcript, .waveform, .timer, .keyHints, .modePill])
            overlay.showTranscript = false
            #expect(overlay.elements == [.header, .targetApp, .waveform, .timer, .keyHints, .modePill])
            overlay.showTargetApp = false
            #expect(overlay.elements == [.header, .waveform, .timer, .keyHints, .modePill])
            overlay.showKeyHints = false
            #expect(overlay.elements == [.header, .waveform, .timer, .modePill])
            overlay.showTimer = false
            #expect(overlay.elements == [.header, .waveform, .modePill])
        }
        #expect(OverlayAppearance.Size.regular.cardWidth == 400 && OverlayAppearance.Size.regular.textSize == 15)
        #expect(OverlayAppearance.Size.large.cardWidth == 480 && OverlayAppearance.Size.large.textSize == 18)
    }

    @Test func compactIsOneRowAndIgnoresTheTranscriptSwitch() {
        var overlay = OverlayAppearance()
        overlay.size = .compact
        #expect(overlay.elements == [.waveform, .timer, .modePill])
        overlay.showTranscript = false
        #expect(overlay.elements == [.waveform, .timer, .modePill])
        overlay.showTimer = false
        #expect(overlay.elements == [.waveform, .modePill])
        #expect(OverlayAppearance.Size.compact.cardWidth == 300)
    }

    // MARK: placement

    private let canvas = CGSize(width: 528, height: 420)
    private let screen = CGRect(x: 0, y: 80, width: 1440, height: 780)
    private let margin: CGFloat = 24

    @Test func bottomAndTopSitTheChosenDistanceFromTheEdge() {
        var overlay = OverlayAppearance()
        overlay.edgeDistance = 100
        let bottom = OverlayPlacement.resolve(overlay, canvas: canvas, visible: screen, caret: nil, margin: margin)
        // The card's bottom edge is the canvas bottom plus the shadow margin.
        #expect(!bottom.growsDown && bottom.origin.y + margin == screen.minY + 100)
        #expect(bottom.origin.x == screen.midX - canvas.width / 2)
        overlay.position = .top
        let top = OverlayPlacement.resolve(overlay, canvas: canvas, visible: screen, caret: nil, margin: margin)
        #expect(top.growsDown && top.origin.y + canvas.height - margin == screen.maxY - 100)
        #expect(overlay.usesEdgeDistance)
    }

    @Test func underTheCursorFollowsTheCaretAndFallsBackToTheBottom() {
        var overlay = OverlayAppearance()
        overlay.position = .underCursor
        #expect(!overlay.usesEdgeDistance)
        // No caret reported: exactly where the bottom position would put it.
        var bottom = overlay
        bottom.position = .bottom
        #expect(OverlayPlacement.resolve(overlay, canvas: canvas, visible: screen, caret: nil, margin: margin)
            == OverlayPlacement.resolve(bottom, canvas: canvas, visible: screen, caret: nil, margin: margin))

        // Room below the line: the card hangs just under the caret, centered on it.
        let caret = CGRect(x: 700, y: 600, width: 2, height: 18)
        let under = OverlayPlacement.resolve(overlay, canvas: canvas, visible: screen, caret: caret, margin: margin)
        #expect(under.growsDown && under.origin.y + canvas.height - margin == caret.minY - 8)
        #expect(under.origin.x == caret.midX - canvas.width / 2)

        // Typing on the last line of the screen: the card goes above the line instead.
        let low = CGRect(x: 700, y: 120, width: 2, height: 18)
        let above = OverlayPlacement.resolve(overlay, canvas: canvas, visible: screen, caret: low, margin: margin)
        #expect(!above.growsDown && above.origin.y + margin == low.maxY + 8)

        // A caret at the screen's edge: the card stays on screen.
        let edge = CGRect(x: 1436, y: 600, width: 2, height: 18)
        let clamped = OverlayPlacement.resolve(overlay, canvas: canvas, visible: screen, caret: edge, margin: margin)
        #expect(clamped.origin.x + canvas.width - margin == screen.maxX - 8)
    }

    @Test func aCaretIsFlippedIntoScreenCoordinatesAndAnEmptyOneIsNoCaret() {
        #expect(CaretLocator.flipped(CGRect(x: 100, y: 200, width: 1, height: 18), mainDisplayHeight: 900) == CGRect(x: 100, y: 682, width: 1, height: 18))
        #expect(CaretLocator.flipped(.zero, mainDisplayHeight: 900) == nil)
        #expect(CaretLocator.flipped(CGRect(x: 100, y: 200, width: 1, height: 18), mainDisplayHeight: nil) == nil)
    }
}
