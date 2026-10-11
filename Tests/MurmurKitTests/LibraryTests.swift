import Foundation
import Testing
@testable import MurmurKit

@MainActor
final class FakeCleanup: TextCleanupService {
    var fails = false
    func clean(_ text: String, instructions: String) async throws -> String {
        if fails { throw ServiceUnavailable() }
        return "Hello there, world."
    }
}

@MainActor
@Suite struct LibraryTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")! }

    private func controller(settings: SettingsStore, history: HistoryStore, cleanup: FakeCleanup? = nil) -> DictationController {
        DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: FakeInsertion(), permissions: FakePermissions(), settings: settings,
            cleanup: cleanup, history: history, frontmostApp: { TargetApp(name: "Notes") }, copyToClipboard: { _ in })
    }

    @Test func insertedTakesLandInHistory() async {
        let d = defaults()
        let settings = SettingsStore(defaults: d), history = HistoryStore(defaults: d)
        let c = controller(settings: settings, history: history)
        c.start(); c.stopAndInsert()
        await c.pendingWork?.value
        #expect(history.entries.map(\.text) == ["hello there world"])
        #expect(history.entries.first?.raw == nil)
        #expect(HistoryStore(defaults: d).entries.count == 1)  // persisted
    }

    @Test func retentionOffKeepsNothing() async {
        let d = defaults()
        let settings = SettingsStore(defaults: d), history = HistoryStore(defaults: d)
        settings.retention = .never
        let c = controller(settings: settings, history: history)
        c.start(); c.stopAndInsert()
        await c.pendingWork?.value
        #expect(history.entries.isEmpty)
    }

    @Test func cleanedModeInsertsCleanTextAndKeepsTheRaw() async {
        let d = defaults()
        let settings = SettingsStore(defaults: d), history = HistoryStore(defaults: d)
        settings.mode = .cleaned
        settings.cleanupEnabled = true
        let c = controller(settings: settings, history: history, cleanup: FakeCleanup())
        c.start(); c.stopAndInsert()
        await c.pendingWork?.value
        #expect(c.lastTranscription?.text == "Hello there, world.")
        #expect(history.entries.first?.raw == "hello there world")
        #expect(history.entries.first?.mode == .cleaned)
    }

    @Test func failedCleanupFallsBackToTheRawText() async {
        let d = defaults()
        let settings = SettingsStore(defaults: d), history = HistoryStore(defaults: d)
        settings.mode = .cleaned
        settings.cleanupEnabled = true
        let cleanup = FakeCleanup()
        cleanup.fails = true
        let c = controller(settings: settings, history: history, cleanup: cleanup)
        c.start(); c.stopAndInsert()
        await c.pendingWork?.value
        #expect(c.lastTranscription?.text == "hello there world")
    }

    @Test func oldHistoryIsPruned() {
        let history = HistoryStore(defaults: defaults())
        let old = HistoryEntry(date: Date().addingTimeInterval(-40 * 86_400), appName: "Notes", mode: .raw, text: "old", audioSeconds: 1, engine: "x")
        history.add(old, retention: .forever)
        history.add(HistoryEntry(date: Date(), appName: "Notes", mode: .raw, text: "new", audioSeconds: 1, engine: "x"), retention: .month)
        #expect(history.entries.map(\.text) == ["new"])
    }

    @Test func dictionaryImportsCSVAndRoundTripsJSON() {
        let store = DictionaryStore(defaults: defaults())
        #expect(store.importData(Data("kube cuttle, kubectl\npost gres, Postgres\nbad line\n".utf8)) == 2)
        store.snippets.append(Snippet(trigger: "today", text: "{date}"))
        #expect(store.snippets[0].isDynamic)
        let other = DictionaryStore(defaults: defaults())
        #expect(other.importData(store.exportJSON()) == 3)
        #expect(other.importData(store.exportJSON()) == 0)  // no duplicates
    }

    @Test func settingsPersistAndReset() {
        let d = defaults()
        let settings = SettingsStore(defaults: d)
        #expect(settings.appearance == .light)
        settings.accent = .mint
        settings.mode = .command
        #expect(SettingsStore(defaults: d).accent == .mint)
        settings.resetAll()
        #expect(settings.accent == .ice && settings.mode == .raw)
        Accent.current = .ice
    }

    @Test func diffFlagsDroppedAndRewrittenWords() {
        // A capital at the start of a sentence and added punctuation are not flagged; a re-cased word mid-sentence is.
        let words = TranscriptDiff.words(raw: "um sounds good i’ll send it thursday", cleaned: "Sounds good. I’ll send it Thursday.")
        #expect(words.map(\.kind) == [.removed, .same, .same, .same, .same, .same, .changed])
    }
}
