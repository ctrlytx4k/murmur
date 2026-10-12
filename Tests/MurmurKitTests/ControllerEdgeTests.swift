import Foundation
import Testing
@testable import MurmurKit

/// The less-travelled paths through the state machine: every one must end somewhere the user can see.
@MainActor
@Suite struct ControllerEdgeTests {
    private struct Boom: LocalizedError { var errorDescription: String? { "The engine fell over." } }

    @Test func aFailedTranscriptionSaysSoAndTypesNothing() async {
        let h = Harness()
        h.engine.result = .failure(Boom())
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(h.controller.state == .error(.transcriptionFailed("The engine fell over.")))
        #expect(h.insertion.inserted.isEmpty && h.controller.lastTranscription == nil)
    }

    @Test func aMicrophoneThatWillNotStartIsReported() {
        let h = Harness()
        h.audio.startError = Boom()
        h.controller.start()
        #expect(h.controller.state == .error(.noInputDevice))
    }

    @Test func missingAccessibilityStopsTheTakeBeforeItRecords() {
        let h = Harness()
        h.permissions.current.accessibility = false
        h.controller.start()
        #expect(h.controller.state == .error(.accessibilityDenied))
        #expect(!h.audio.started)
    }

    @Test func anErrorCanBeDismissedAndEscClearsIt() {
        let h = Harness()
        h.permissions.current.microphone = false
        h.controller.start()
        h.controller.dismissError()
        #expect(h.controller.state == .idle)
        h.controller.start()
        h.controller.hotkey(.cancel)
        #expect(h.controller.state == .idle)
        // Dismissing when nothing is wrong changes nothing.
        h.controller.dismissError()
        #expect(h.controller.state == .idle)
    }

    @Test func theDoubleTapShortcutStartsAndStops() async {
        let h = Harness()
        h.controller.hotkey(.toggle)
        #expect(h.controller.state.isRecording)
        h.controller.hotkey(.toggle)
        await h.settle()
        #expect(h.insertion.inserted == ["hello there world"])
    }

    @Test func returnEndsTheTakeAndEscDropsIt() async {
        let h = Harness()
        h.controller.start()
        h.controller.hotkey(.commit)
        await h.settle()
        #expect(h.insertion.inserted.count == 1)

        #expect(await h.becomesIdle())
        h.controller.start()
        h.controller.hotkey(.cancel)
        await h.settle()
        #expect(h.audio.cancelled && h.insertion.inserted.count == 1 && h.controller.state == .idle)
    }

    @Test func stopKeysDoNothingWhenNoTakeIsRunning() async {
        let h = Harness()
        h.controller.hotkey(.commit)
        h.controller.hotkey(.up)
        h.controller.stopAndInsert()
        // "Copy instead" with no take must not leak into the next one.
        h.controller.hotkey(.copy)
        #expect(h.controller.state == .idle && h.controller.pendingWork == nil)
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(h.insertion.inserted == ["hello there world"] && h.copied.isEmpty)
    }

    @Test func aSecondStartWhileBusyIsIgnored() async {
        let h = Harness()
        h.controller.start()
        let first = h.controller.state
        h.controller.start()
        #expect(h.controller.state == first)
        h.controller.stopAndInsert()
        h.controller.start()
        #expect(h.controller.state == .processing)
        await h.settle()
        #expect(h.insertion.inserted.count == 1)
    }

    @Test func reinsertTypesTheLastTextAgain() async {
        let h = Harness()
        h.controller.reinsertLast()
        #expect(h.controller.state == .idle)  // nothing to re-insert yet
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(await h.becomesIdle())
        h.controller.reinsertLast()
        await h.settle()
        #expect(h.insertion.inserted == ["hello there world", "hello there world"])
        #expect(h.controller.lastTranscription?.mode == .raw)
    }

    @Test func copyLastDoesNothingBeforeTheFirstTake() {
        let h = Harness()
        h.controller.copyLast()
        h.controller.undoLast()
        #expect(h.copied.isEmpty && h.insertion.undone.isEmpty)
    }

    @Test func aTakeStopsItselfAtTheMaximumLength() async {
        let insertion = FakeInsertion()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        settings.maxLength = .one
        // One minute, scaled down to 60 ms.
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: insertion, permissions: FakePermissions(), settings: settings,
            maxLengthScale: 0.001, frontmostApp: { TargetApp(name: "Notes") }, copyToClipboard: { _ in })
        controller.start()
        for _ in 0..<200 where insertion.inserted.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(insertion.inserted == ["hello there world"])
    }

    @Test func cleanedModeWithCleanupSwitchedOffInsertsTheSpokenText() async {
        let cleanup = FakeCleanup()
        let h = Harness(cleanup: cleanup)
        h.settings.mode = .cleaned
        h.settings.cleanupEnabled = false
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(cleanup.instructions.isEmpty)
        #expect(h.insertion.inserted == ["hello there world"] && h.controller.lastTranscription?.mode == .raw)
    }

    @Test func theCustomPresetSendsTheUsersOwnInstructions() async {
        let cleanup = FakeCleanup()
        let h = Harness(cleanup: cleanup)
        h.settings.mode = .cleaned
        h.settings.cleanupEnabled = true
        h.settings.cleanupPreset = .custom
        h.settings.customInstructions = "Write like a pirate."
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(cleanup.instructions == ["Write like a pirate."])
        #expect(h.controller.lastTranscription?.mode == .cleaned)
    }

    @Test func aCleanupThatChangesNothingStillCountsAsCleaned() async {
        final class Echo: TextCleanupService {
            let availability = CleanupAvailability.available(model: "Echo")
            func clean(_ text: String, instructions: String) async throws -> String { text }
        }
        let d = UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: d), history = HistoryStore(defaults: d)
        settings.mode = .cleaned
        settings.cleanupEnabled = true
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: FakeInsertion(), permissions: FakePermissions(), settings: settings,
            cleanup: Echo(), history: history, frontmostApp: { TargetApp(name: "Notes") }, copyToClipboard: { _ in })
        controller.start()
        controller.stopAndInsert()
        await controller.pendingWork?.value
        #expect(controller.lastTranscription?.mode == .cleaned)
        #expect(history.entries.first?.mode == .cleaned && history.entries.first?.raw == nil)
    }

    @Test func dictionaryWordsAreSwappedBeforeTheTextGoesIn() async {
        let d = UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!
        let dictionary = DictionaryStore(defaults: d)
        dictionary.entries = [DictionaryEntry(spoken: "hello there", written: "Ahoy")]
        let insertion = FakeInsertion()
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: insertion, permissions: FakePermissions(), settings: SettingsStore(defaults: d),
            dictionary: dictionary, frontmostApp: { TargetApp(name: "Notes") }, copyToClipboard: { _ in })
        controller.start()
        controller.stopAndInsert()
        await controller.pendingWork?.value
        #expect(insertion.inserted == ["Ahoy world"])
    }

    @Test func copyInsteadIsKeptInHistoryAndCannotBeUndone() async {
        let d = UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!
        let history = HistoryStore(defaults: d)
        let insertion = FakeInsertion()
        var copied: [String] = []
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: insertion, permissions: FakePermissions(), settings: SettingsStore(defaults: d),
            history: history, frontmostApp: { TargetApp(name: "Notes") }, copyToClipboard: { copied.append($0) })
        controller.start()
        controller.hotkey(.copy)
        await controller.pendingWork?.value
        #expect(copied == ["hello there world"] && insertion.inserted.isEmpty)
        #expect(history.entries.map(\.text) == ["hello there world"])
        controller.undoLast()
        #expect(insertion.undone.isEmpty)
    }

    @Test func aPasswordFieldBlocksATakeButNotCopyInstead() async {
        let h = Harness()
        h.insertion.isSecureInputActive = true
        h.controller.start()
        h.controller.stopAndCopy()
        await h.settle()
        // Nothing is typed, so the field is never touched; the text is on the clipboard as asked.
        #expect(h.copied == ["hello there world"] && h.insertion.inserted.isEmpty)
    }

    @Test func aMicrophoneChangeIsNoticedMidTake() {
        let h = Harness()
        h.controller.start()
        h.controller.noteDeviceChange("USB mic disconnected. Now using MacBook Pro Microphone.")
        #expect(h.controller.deviceNotice == "USB mic disconnected. Now using MacBook Pro Microphone.")
        #expect(h.controller.state.isRecording)
    }

    @Test func levelsScrollAndStayInRange() {
        let h = Harness()
        h.controller.start()
        h.audio.onLevel?(3)
        h.audio.onLevel?(-1)
        #expect(h.controller.levels.count == DictationController.levelCount)
        #expect(h.controller.levels.suffix(2) == [1, 0])
        // Levels arriving after the take are ignored.
        h.controller.cancel()
        h.audio.onLevel?(0.5)
        #expect(h.controller.levels.last == 0)
    }

    @Test func theTargetAppIsCapturedWhenTheTakeStarts() async {
        let h = Harness(app: TargetApp(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"))
        h.controller.start()
        #expect(h.controller.target?.name == "Slack")
        h.controller.stopAndInsert()
        await h.settle()
        #expect(h.controller.state == .inserted(InsertionSummary(appName: "Slack", wordCount: 3)))
        #expect(h.controller.lastTranscription?.appName == "Slack")
    }
}
