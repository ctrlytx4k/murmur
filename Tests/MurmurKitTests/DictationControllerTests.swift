import Foundation
import Testing
@testable import MurmurKit

@MainActor
final class FakeAudio: AudioCaptureService {
    var startError: Error?
    var started = false
    var cancelled = false
    var onLevel: ((Float) -> Void)?
    func start(deviceID: String?, onLevel: @escaping (Float) -> Void) throws {
        if let startError { throw startError }
        started = true
        self.onLevel = onLevel
    }
    func stop() async throws -> AudioClip { AudioClip(samples: [0, 0.1, 0]) }
    func cancel() { cancelled = true }
}

@MainActor
final class FakeEngine: TranscriptionEngine {
    let displayName = "Fake"
    var result: Result<String, Error> = .success("hello there world")
    func transcribe(_ clip: AudioClip) async throws -> String { try result.get() }
}

@MainActor
final class FakeInsertion: TextInsertionService {
    var isSecureInputActive = false
    var fails = false
    var inserted: [String] = []
    var undone: [InsertionReceipt] = []
    func insert(_ text: String) async throws -> InsertionReceipt {
        if fails { throw InsertionFailure.leftOnClipboard }
        inserted.append(text)
        return InsertionReceipt(text: text)
    }
    func undo(_ receipt: InsertionReceipt) async -> Bool {
        undone.append(receipt)
        return true
    }
}

@MainActor
final class FakePermissions: PermissionsService {
    var current = PermissionSnapshot.allGranted
    var requested: [Permission] = []
    func snapshot() -> PermissionSnapshot { current }
    func request(_ permission: Permission) { requested.append(permission) }
}

@MainActor
struct Harness {
    let audio = FakeAudio()
    let engine = FakeEngine()
    let insertion = FakeInsertion()
    let permissions = FakePermissions()
    let settings: SettingsStore
    let controller: DictationController
    var copied: [String] { box.values }
    private let box = Box()

    final class Box { var values: [String] = [] }

    init() {
        let suite = "murmur-tests-\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let box = box
        controller = DictationController(
            audio: audio, engine: engine, insertion: insertion, permissions: permissions, settings: settings,
            tapThreshold: 0,
            frontmostApp: { TargetApp(name: "Notes") },
            copyToClipboard: { box.values.append($0) },
            insertedHold: .milliseconds(20), errorHold: .milliseconds(20))
    }

    func settle() async {
        await controller.pendingWork?.value
    }
}

@MainActor
@Suite struct DictationControllerTests {
    @Test func happyPathGoesThroughEveryState() async throws {
        let h = Harness()
        #expect(h.controller.state == .idle)

        h.controller.start()
        #expect(h.controller.state.isRecording)
        #expect(h.controller.target?.name == "Notes")

        h.controller.stopAndInsert()
        #expect(h.controller.state == .processing)

        await h.settle()
        #expect(h.controller.state == .inserted(InsertionSummary(appName: "Notes", wordCount: 3)))
        #expect(h.insertion.inserted == ["hello there world"])
        #expect(h.controller.lastTranscription?.text == "hello there world")
        #expect(h.controller.canUndoLast)

        try await Task.sleep(for: .milliseconds(80))
        #expect(h.controller.state == .idle)
    }

    @Test func pushToTalkFollowsKeyDownAndUp() async {
        let h = Harness()
        h.settings.behavior = .pushToTalk
        h.controller.hotkey(.down)
        #expect(h.controller.state.isRecording)
        h.controller.hotkey(.up)
        #expect(h.controller.state == .processing)
        await h.settle()
    }

    @Test func aQuickTapKeepsListeningUntilTheNextPress() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let insertion = FakeInsertion()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: insertion, permissions: FakePermissions(), settings: settings,
            frontmostApp: { nil }, copyToClipboard: { _ in }, now: { clock })

        controller.hotkey(.down)
        clock += 0.1
        controller.hotkey(.up)
        #expect(controller.state.isRecording && controller.isLatched)

        // The next press ends the take; its release does nothing more.
        clock += 3
        controller.hotkey(.down)
        #expect(controller.state == .processing && !controller.isLatched)
        controller.hotkey(.up)
        await controller.pendingWork?.value
        #expect(insertion.inserted.count == 1)
    }

    @Test func aLongHoldIsPlainPushToTalk() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let controller = DictationController(
            audio: FakeAudio(), engine: FakeEngine(), insertion: FakeInsertion(), permissions: FakePermissions(), settings: settings,
            frontmostApp: { nil }, copyToClipboard: { _ in }, now: { clock })
        controller.hotkey(.down)
        clock += 2
        controller.hotkey(.up)
        #expect(controller.state == .processing)
        await controller.pendingWork?.value
    }

    @Test func toggleIgnoresKeyUp() async {
        let h = Harness()
        h.settings.behavior = .toggle
        h.controller.hotkey(.down)
        h.controller.hotkey(.up)
        #expect(h.controller.state.isRecording)
        h.controller.hotkey(.down)
        #expect(h.controller.state == .processing)
        await h.settle()
    }

    @Test func missingMicrophoneIsAVisibleErrorAndNothingRecords() {
        let h = Harness()
        h.permissions.current.microphone = false
        h.controller.start()
        #expect(h.controller.state == .error(.microphoneDenied))
        #expect(!h.audio.started)
    }

    @Test func permissionsAreReadLiveOnEveryStart() {
        let h = Harness()
        h.permissions.current.accessibility = false
        h.controller.start()
        #expect(h.controller.state == .error(.accessibilityDenied))

        h.permissions.current.accessibility = true
        h.controller.start()
        #expect(h.controller.state.isRecording)
    }

    @Test func secureInputDiscardsTheTake() async {
        let h = Harness()
        h.controller.start()
        h.insertion.isSecureInputActive = true
        h.controller.stopAndInsert()
        await h.settle()
        #expect(h.controller.state == .error(.secureInput))
        #expect(h.insertion.inserted.isEmpty)
        #expect(h.controller.lastTranscription == nil)
        #expect(h.copied.isEmpty)
    }

    @Test func failedInsertionKeepsTheTextForCopying() async {
        let h = Harness()
        h.insertion.fails = true
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(h.controller.state == .error(.insertionFailed(appName: "Notes")))
        #expect(h.controller.lastTranscription?.text == "hello there world")
        #expect(!h.controller.canUndoLast)
    }

    @Test func emptyTranscriptIsReportedNotSilent() async {
        let h = Harness()
        h.engine.result = .success("   ")
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()
        #expect(h.controller.state == .error(.nothingHeard))
        #expect(h.insertion.inserted.isEmpty)
    }

    @Test func cancelWhileRecordingDropsTheTake() async {
        let h = Harness()
        h.controller.start()
        h.controller.hotkey(.cancel)
        #expect(h.controller.state == .idle)
        #expect(h.audio.cancelled)
        #expect(h.insertion.inserted.isEmpty)
    }

    @Test func cancelWhileProcessingIgnoresTheLateResult() async {
        let h = Harness()
        h.controller.start()
        h.controller.stopAndInsert()
        h.controller.cancel()
        await h.settle()
        #expect(h.controller.state == .idle)
        #expect(h.insertion.inserted.isEmpty)
    }

    @Test func errorsClearThemselves() async throws {
        let h = Harness()
        h.permissions.current.microphone = false
        h.controller.start()
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.controller.state == .idle)
    }

    @Test func undoIsOfferedOnceAndCopyUsesTheLastText() async {
        let h = Harness()
        h.controller.start()
        h.controller.stopAndInsert()
        await h.settle()

        h.controller.copyLast()
        #expect(h.copied == ["hello there world"])

        h.controller.undoLast()
        await h.settle()
        #expect(h.insertion.undone == [InsertionReceipt(text: "hello there world")])
        #expect(!h.controller.canUndoLast)
        h.controller.undoLast()
        await h.settle()
        #expect(h.insertion.undone.count == 1)
    }

    @Test func silenceIsFlaggedAfterThreeQuietSeconds() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let audio = FakeAudio()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let controller = DictationController(
            audio: audio, engine: FakeEngine(), insertion: FakeInsertion(), permissions: FakePermissions(), settings: settings,
            frontmostApp: { nil }, copyToClipboard: { _ in }, now: { clock })
        controller.start()
        audio.onLevel?(0.5)
        #expect(!controller.isSilent)
        clock += 4
        audio.onLevel?(0)
        #expect(controller.isSilent)
        audio.onLevel?(0.4)
        #expect(!controller.isSilent)
    }
}

@MainActor
@Suite struct ShortcutTests {
    @Test func keycapsFollowMacOrder() {
        #expect(Shortcut.optionSpace.keycaps == ["⌥", "Space"])
        #expect(Shortcut(keyCode: 49, modifiers: [.command, .control]).keycaps == ["⌃", "⌘", "Space"])
        #expect(Shortcut(keyCode: 61, modifiers: [], isModifierOnly: true).keycaps == ["Right ⌥"])
    }

    @Test func knownSystemShortcutsAreFlagged() {
        #expect(Shortcut(keyCode: 49, modifiers: .control).systemConflict != nil)
        #expect(Shortcut(keyCode: 49, modifiers: .command).systemConflict != nil)
        #expect(Shortcut.optionSpace.systemConflict == nil)
    }
}
