import AppKit
import Foundation
import Testing
@testable import MurmurKit

@Suite struct HotkeyDecisionTests {
    private let option: UInt64 = 0x8_0000, command: UInt64 = 0x10_0000
    private func config(_ dictation: Shortcut = .optionSpace, toggle: Bool = false, recording: Bool = false) -> TapConfig {
        TapConfig(
            bindings: HotkeyBindings(
                dictation: dictation, cycleMode: Shortcut(keyCode: 46, modifiers: .option),
                reinsert: Shortcut(keyCode: 9, modifiers: [.control, .option]), history: Shortcut(keyCode: 4, modifiers: [.control, .option]),
                returnCommits: toggle),
            recording: recording)
    }

    @Test func keyWithModifierGoesDownAndUpAndIsSwallowed() {
        var c = config()
        let down = HotkeyDecision.decide(type: .keyDown, keyCode: 49, flags: option, autorepeat: false, config: &c)
        #expect(down.output == .event(.down) && down.swallow)
        // Holding the key repeats; repeats are swallowed and not reported again.
        let again = HotkeyDecision.decide(type: .keyDown, keyCode: 49, flags: option, autorepeat: true, config: &c)
        #expect(again.output == nil && again.swallow)
        // Option is often released before Space.
        let up = HotkeyDecision.decide(type: .keyUp, keyCode: 49, flags: 0, autorepeat: false, config: &c)
        #expect(up.output == .event(.up) && up.swallow)
    }

    @Test func plainSpaceAndOtherModifiersPassThrough() {
        var c = config()
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 49, flags: 0, autorepeat: false, config: &c).swallow == false)
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 49, flags: command, autorepeat: false, config: &c).output == nil)
        #expect(HotkeyDecision.decide(type: .keyUp, keyCode: 49, flags: 0, autorepeat: false, config: &c).output == nil)
    }

    @Test func loneModifierUsesTheRightKeyOnly() {
        var c = config(Shortcut(keyCode: 61, modifiers: [], isModifierOnly: true))
        // Left Option (58) changes the same flag but is a different key.
        #expect(HotkeyDecision.decide(type: .flagsChanged, keyCode: 58, flags: option | 0x20, autorepeat: false, config: &c).output == nil)
        let down = HotkeyDecision.decide(type: .flagsChanged, keyCode: 61, flags: option | 0x40, autorepeat: false, config: &c)
        #expect(down.output == .event(.down) && !down.swallow)
        #expect(HotkeyDecision.decide(type: .flagsChanged, keyCode: 61, flags: 0, autorepeat: false, config: &c).output == .event(.up))
    }

    @Test func escapeAndReturnOnlyActWhileRecording() {
        var idle = config(toggle: true)
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 53, flags: 0, autorepeat: false, config: &idle).swallow == false)
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 36, flags: 0, autorepeat: false, config: &idle).output == nil)

        var recording = config(toggle: true, recording: true)
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 53, flags: 0, autorepeat: false, config: &recording).output == .event(.cancel))
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 36, flags: 0, autorepeat: false, config: &recording).output == .event(.commit))

        var pushToTalk = config(toggle: false, recording: true)
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 36, flags: 0, autorepeat: false, config: &pushToTalk).output == nil)
    }

    @Test func otherShortcutsFireOnce() {
        var c = config()
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 46, flags: option, autorepeat: false, config: &c).output == .action(.cycleMode))
        #expect(HotkeyDecision.decide(type: .keyDown, keyCode: 46, flags: option, autorepeat: true, config: &c).output == nil)
    }
}

@MainActor
@Suite struct TextProcessorTests {
    private let entries = [
        DictionaryEntry(spoken: "kube cuttle", written: "kubectl"),
        DictionaryEntry(spoken: "jason", written: "JSON", scope: "Xcode, Terminal"),
        DictionaryEntry(spoken: "post gres", written: "Postgres"),
    ]

    @Test func replacesWholePhrasesInAnyCase() {
        let out = TextProcessor.applyDictionary(entries, to: "Run Kube  Cuttle against post gres, not postgresql.", app: "Notes")
        #expect(out == "Run kubectl against Postgres, not postgresql.")
    }

    @Test func scopedEntriesOnlyApplyInTheirApps() {
        #expect(TextProcessor.applyDictionary(entries, to: "ask jason", app: "Notes") == "ask jason")
        #expect(TextProcessor.applyDictionary(entries, to: "parse the jason", app: "Xcode") == "parse the JSON")
    }

    @Test func snippetNeedsTheWholeTakeToMatch() {
        let snippets = [Snippet(trigger: "my address", text: "1 Example Street"), Snippet(trigger: "today’s date", text: "{date}")]
        #expect(TextProcessor.snippet(for: "My address.", in: snippets)?.text == "1 Example Street")
        #expect(TextProcessor.snippet(for: "insert my address", in: snippets) != nil)
        #expect(TextProcessor.snippet(for: "Today's date", in: snippets) != nil)
        #expect(TextProcessor.snippet(for: "send it to my address please", in: snippets) == nil)
    }

    @Test func tokensExpand() {
        let out = TextProcessor.expand("{clipboard} at {time}", now: Date(timeIntervalSince1970: 0), clipboard: "copied")
        #expect(out.hasPrefix("copied at "))
        #expect(!out.contains("{"))
    }

    @Test func snippetTakesSkipTheSpeechTextEntirely() async {
        let d = UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: d)
        let dictionary = DictionaryStore(defaults: d)
        dictionary.snippets = [Snippet(trigger: "hello there world", text: "Snippet body")]
        let insertion = FakeInsertion()
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: insertion, permissions: FakePermissions(), settings: settings,
            dictionary: dictionary, frontmostApp: { nil }, copyToClipboard: { _ in })
        controller.start(); controller.stopAndInsert()
        await controller.pendingWork?.value
        #expect(insertion.inserted == ["Snippet body"])
    }

    @Test func aModelThatIsNotReadyStopsTheTakeBeforeItStarts() {
        final class LoadingEngine: TranscriptionEngine {
            let displayName = "loading"
            var readiness: EngineReadiness { .preparing(name: "parakeet-v3", progress: 0.5) }
            func transcribe(_ clip: AudioClip) async throws -> String { "" }
        }
        let audio = FakeAudio()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let controller = DictationController(
            audio: audio, engine: LoadingEngine(), insertion: FakeInsertion(), permissions: FakePermissions(), settings: settings,
            frontmostApp: { nil }, copyToClipboard: { _ in })
        controller.start()
        #expect(controller.state == .error(.modelNotReady(name: "parakeet-v3", progress: 0.5)))
        #expect(!audio.started)
    }
}

@MainActor
@Suite struct ClipboardRestoreTests {
    /// A private pasteboard, so the tests never touch the real clipboard.
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("murmur-tests-\(UUID().uuidString)")) }

    @Test func everyTypeOfEveryItemComesBackInOrder() {
        let pb = pasteboard()
        let rich = NSPasteboardItem()
        rich.setData(Data("{\\rtf1 hi}".utf8), forType: .rtf)
        rich.setString("<b>hi</b>", forType: .html)
        rich.setString("hi", forType: .string)
        let image = NSPasteboardItem()
        image.setData(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), forType: .png)
        pb.clearContents()
        pb.writeObjects([rich, image])

        let saved = PasteboardSnapshot.take(pb)
        pb.clearContents()
        pb.setString("dictated text", forType: .string)
        saved.restore(to: pb)

        #expect(PasteboardSnapshot.take(pb).matches(saved))
        #expect(pb.pasteboardItems?.count == 2)
        #expect(pb.pasteboardItems?.first?.types.first == .rtf)
        #expect(pb.string(forType: .string) == "hi")
    }

    @Test func anEmptyClipboardIsRestoredToEmpty() {
        let pb = pasteboard()
        pb.clearContents()
        let saved = PasteboardSnapshot.take(pb)
        pb.setString("dictated text", forType: .string)
        saved.restore(to: pb)
        #expect(pb.pasteboardItems?.isEmpty ?? true)
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func withoutAccessibilityTheTextIsLeftOnTheClipboard() async {
        // The test process has no Accessibility permission, which is exactly this path.
        guard !AXIsProcessTrusted() else { return }
        let pb = pasteboard()
        pb.clearContents()
        pb.setString("what the user had copied", forType: .string)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        settings.addsTrailingSpace = false
        let insertion = PasteInsertion(settings: settings, pasteboard: pb)
        await #expect(throws: InsertionFailure.leftOnClipboard) { _ = try await insertion.insert("hello") }
        #expect(pb.string(forType: .string) == "hello")
    }
}
