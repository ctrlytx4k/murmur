import Foundation
import Testing
@testable import MurmurKit

/// A track made of loudness frames; each clip carries its start time in its first sample, so the fake engine can tell them apart.
private struct MeetingFakeTrack: MeetingTrack {
    var frames: [Float]
    func levels() async throws -> [Float] { frames }
    func clip(from start: Double, to end: Double) async throws -> AudioClip { AudioClip(samples: [Float(start)]) }

    /// Seconds of silence and speech, in order.
    static func of(_ parts: [(seconds: Double, speech: Bool)]) -> MeetingFakeTrack {
        MeetingFakeTrack(frames: parts.flatMap { [Float](repeating: $0.speech ? 0.1 : 0, count: Int($0.seconds / SpeechSegmenter.frame)) })
    }
}

@MainActor
private final class MeetingFakeEngine: TranscriptionEngine {
    let displayName = "fake-engine"
    var readiness = EngineReadiness.ready
    var fails = false
    var calls = 0
    /// What the engine "hears". Deliberately messy: the transcript must come out exactly like this.
    var reply: (AudioClip) -> String = { "um so   this is, like, what was said at \(Int($0.samples.first ?? -1))" }
    struct Broken: LocalizedError { var errorDescription: String? { "The engine fell over." } }

    func transcribe(_ clip: AudioClip) async throws -> String {
        calls += 1
        if fails { throw Broken() }
        return reply(clip)
    }
}

@MainActor
private final class FakeMeetingAudio: MeetingAudioService {
    var started: (microphone: URL, call: URL?)?
    var asked = 0
    var failsToStart = false
    var result = MeetingRecording(duration: 90)
    struct NoMicrophone: Error {}

    func start(microphone: URL, call: URL?, microphoneID: String?, onLevel: @escaping (Float) -> Void) throws {
        if failsToStart { throw NoMicrophone() }
        started = (microphone, call)
        FileManager.default.createFile(atPath: microphone.path, contents: Data([1]))
        if let call { FileManager.default.createFile(atPath: call.path, contents: Data([1])) }
    }

    func stop() -> MeetingRecording { result }
    func requestSystemAudio() { asked += 1 }
}

@MainActor
@Suite struct MeetingTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("murmur-meeting-tests-\(UUID().uuidString)") }

    private struct Rig {
        let controller: MeetingController
        let store: MeetingStore
        let settings: SettingsStore
        let audio: FakeMeetingAudio
        let engine: MeetingFakeEngine
        let permissions: DemoPermissions
    }

    private func rig(microphone: Bool = true) -> Rig {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let store = MeetingStore(directory: directory())
        let audio = FakeMeetingAudio(), engine = MeetingFakeEngine()
        let permissions = DemoPermissions(PermissionSnapshot(microphone: microphone, accessibility: true))
        let controller = MeetingController(audio: audio, engine: engine, store: store, settings: settings, permissions: permissions) { url in
            // You speak at 1 s; the call answers at 5 s.
            url.lastPathComponent == "call.caf"
                ? MeetingFakeTrack.of([(5, false), (2, true), (1, false)])
                : MeetingFakeTrack.of([(1, false), (2, true), (5, false)])
        }
        Accent.current = .ice
        return Rig(controller: controller, store: store, settings: settings, audio: audio, engine: engine, permissions: permissions)
    }

    // MARK: finding speech

    @Test func silenceGivesNoSegmentsAndSpeechGivesOnePerTurn() {
        #expect(SpeechSegmenter.segments(levels: []).isEmpty)
        #expect(SpeechSegmenter.segments(levels: MeetingFakeTrack.of([(10, false)]).frames).isEmpty)
        let turns = SpeechSegmenter.segments(levels: MeetingFakeTrack.of([(1, false), (2, true), (3, false), (4, true), (1, false)]).frames)
        #expect(turns.count == 2)
        // Each turn starts a little before the speech and ends a little after it.
        #expect(abs(turns[0].lowerBound - 0.85) < 0.05 && abs(turns[0].upperBound - 3.15) < 0.05)
        #expect(abs(turns[1].lowerBound - 5.85) < 0.05 && abs(turns[1].upperBound - 10.15) < 0.05)
    }

    @Test func aShortPauseStaysInOneTurnAndAClickIsIgnored() {
        let paused = SpeechSegmenter.segments(levels: MeetingFakeTrack.of([(1, false), (2, true), (0.3, false), (2, true), (1, false)]).frames)
        #expect(paused.count == 1)
        let click = SpeechSegmenter.segments(levels: MeetingFakeTrack.of([(1, false), (0.1, true), (3, false)]).frames)
        #expect(click.isEmpty)
    }

    @Test func aLongMonologueIsCutIntoPiecesTheEngineCanTake() {
        let pieces = SpeechSegmenter.segments(levels: MeetingFakeTrack.of([(1, false), (70, true), (1, false)]).frames)
        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { $0.upperBound - $0.lowerBound <= SpeechSegmenter.longest + 0.1 })
        // Nothing is lost between the pieces.
        for (previous, next) in zip(pieces, pieces.dropFirst()) { #expect(abs(next.lowerBound - previous.upperBound) < 0.03) }
    }

    @Test func speechStandsOutAboveASteadyRoomNoise() {
        let noisy = MeetingFakeTrack(frames: MeetingFakeTrack.of([(2, false), (2, true), (2, false)]).frames.map { max($0, 0.01) })
        #expect(SpeechSegmenter.segments(levels: noisy.frames).count == 1)
    }

    // MARK: the transcript

    @Test func bothTracksComeBackInTimeOrderWithYouAndOthers() async throws {
        let engine = MeetingFakeEngine()
        let result = try await MeetingTranscriber.transcribe(
            microphone: MeetingFakeTrack.of([(1, false), (2, true), (6, false), (2, true)]), call: MeetingFakeTrack.of([(5, false), (2, true), (4, false)]),
            engine: engine, onProgress: { _ in })
        #expect(result.lines.map(\.speaker) == [.you, .others, .you])
        #expect(result.lines.map { Int($0.start.rounded()) } == [1, 5, 9])
        #expect(result.note == nil)
    }

    @Test func theTranscriptIsExactlyWhatTheEngineHeard() async throws {
        let engine = MeetingFakeEngine()
        let result = try await MeetingTranscriber.transcribe(microphone: MeetingFakeTrack.of([(1, false), (2, true), (1, false)]), call: nil, engine: engine, onProgress: { _ in })
        // No clean-up, no dictionary, no re-casing: only the surrounding whitespace is trimmed.
        #expect(result.lines.map(\.text) == ["um so   this is, like, what was said at 0"])
        // Without a call track nobody is named.
        #expect(result.lines.first?.speaker == nil)
    }

    @Test func progressRunsFromZeroToOne() async throws {
        var seen: [Double] = []
        _ = try await MeetingTranscriber.transcribe(
            microphone: MeetingFakeTrack.of([(1, false), (2, true), (3, false), (2, true), (1, false)]), call: nil, engine: MeetingFakeEngine(), onProgress: { seen.append($0) })
        #expect(seen.first == 0 && seen.last == 1 && seen == seen.sorted())
    }

    @Test func aSilentCallTrackOrNoSpeechIsSaidOutLoud() async throws {
        let silentCall = try await MeetingTranscriber.transcribe(
            microphone: MeetingFakeTrack.of([(1, false), (2, true), (1, false)]), call: MeetingFakeTrack.of([(4, false)]), callWasSilent: true, engine: MeetingFakeEngine(), onProgress: { _ in })
        #expect(silentCall.lines.count == 1 && silentCall.note?.contains("System Audio Recording") == true)
        let nothing = try await MeetingTranscriber.transcribe(microphone: MeetingFakeTrack.of([(4, false)]), call: nil, engine: MeetingFakeEngine(), onProgress: { _ in })
        #expect(nothing.lines.isEmpty && nothing.note == "No speech was heard in this recording.")
    }

    @Test func anEngineThatIsNotReadyIsReportedBeforeAnythingIsTranscribed() async {
        let engine = MeetingFakeEngine()
        engine.readiness = .preparing(name: "parakeet-v3", progress: 0.4)
        await #expect(throws: MeetingTranscriptionFailure.self) {
            _ = try await MeetingTranscriber.transcribe(microphone: MeetingFakeTrack.of([(1, false), (2, true)]), call: nil, engine: engine, onProgress: { _ in })
        }
        #expect(engine.calls == 0)
    }

    // MARK: the store

    @Test func theRawTranscriptIsWrittenOnceAndNeverReplaced() {
        let store = MeetingStore(directory: directory())
        let meeting = Meeting(title: "Sync", date: Date(), duration: 60, includesCallAudio: true)
        store.add(meeting)
        let raw = [MeetingLine(start: 1, speaker: .you, text: "um hello")]
        #expect(store.finishTranscription(meeting.id, lines: raw, engine: "fake"))
        // A second attempt, for whatever reason, changes nothing.
        #expect(!store.finishTranscription(meeting.id, lines: [MeetingLine(start: 1, speaker: .you, text: "Hello.")], engine: "other"))
        #expect(store.meeting(meeting.id)?.lines == raw && store.meeting(meeting.id)?.engine == "fake")
        // Renaming and deleting the audio leave it alone too.
        store.rename(meeting.id, to: "Weekly sync")
        store.deleteAudio(meeting.id)
        #expect(store.meeting(meeting.id)?.lines == raw && store.meeting(meeting.id)?.title == "Weekly sync" && store.meeting(meeting.id)?.hasAudio == false)
    }

    @Test func meetingsSurviveARelaunchNewestFirstAndDeletingRemovesTheFolder() {
        let folder = directory()
        let store = MeetingStore(directory: folder)
        var older = Meeting(title: "Older", date: Date(timeIntervalSince1970: 1_000), duration: 60, includesCallAudio: false)
        older.setTranscript([MeetingLine(start: 2, speaker: nil, text: "first")], engine: "fake", note: "a note")
        let newer = Meeting(title: "Newer", date: Date(timeIntervalSince1970: 2_000), duration: 120, includesCallAudio: true)
        store.add(older)
        store.add(newer)
        let reopened = MeetingStore(directory: folder)
        #expect(reopened.meetings == [newer, older])
        #expect(reopened.meetings.last?.lines.first?.text == "first" && reopened.meetings.last?.note == "a note")
        reopened.delete(older.id)
        #expect(!FileManager.default.fileExists(atPath: reopened.folder(for: older.id).path))
        #expect(MeetingStore(directory: folder).meetings == [newer])
    }

    // MARK: recording

    @Test func stopSavesTheMeetingTranscribesItAndDeletesTheAudio() async {
        let rig = rig()
        rig.controller.start()
        #expect(rig.controller.state.isRecording && rig.audio.started?.call != nil)
        #expect(rig.store.meetings.isEmpty)
        rig.controller.stop()
        // Saved the moment recording stops, before a word is transcribed.
        #expect(rig.store.meetings.count == 1 && rig.store.meetings[0].isTranscribed == false)
        await rig.controller.pendingWork?.value
        let meeting = rig.store.meetings[0]
        #expect(rig.controller.state == .idle && rig.controller.latest == meeting.id)
        #expect(meeting.isTranscribed && meeting.duration == 90 && meeting.includesCallAudio && meeting.engine == "fake-engine")
        #expect(meeting.lines.map(\.speaker) == [.you, .others])
        // The default is to delete the audio once the transcript exists.
        #expect(!meeting.hasAudio && !FileManager.default.fileExists(atPath: rig.store.microphoneURL(for: meeting.id).path))
    }

    @Test func theAudioIsKeptWhenSettingsSaySo() async {
        let rig = rig()
        rig.settings.meetingAudio = .keep
        rig.controller.start()
        rig.controller.stop()
        await rig.controller.pendingWork?.value
        let meeting = rig.store.meetings[0]
        #expect(meeting.isTranscribed && meeting.hasAudio && FileManager.default.fileExists(atPath: rig.store.microphoneURL(for: meeting.id).path))
    }

    @Test func microphoneOnlyRecordsNoCallTrackAndNamesNobody() async {
        let rig = rig()
        rig.settings.meetingSource = .microphoneOnly
        rig.controller.start()
        #expect(rig.audio.started != nil && rig.audio.started?.call == nil)
        rig.controller.stop()
        await rig.controller.pendingWork?.value
        #expect(rig.store.meetings[0].includesCallAudio == false && rig.store.meetings[0].lines.allSatisfy { $0.speaker == nil })
    }

    @Test func aFailedTranscriptionKeepsTheAudioAndCanBeTriedAgain() async {
        let rig = rig()
        rig.engine.fails = true
        rig.controller.start()
        rig.controller.stop()
        await rig.controller.pendingWork?.value
        var meeting = rig.store.meetings[0]
        #expect(!meeting.isTranscribed && meeting.problem == "The engine fell over." && meeting.hasAudio)
        #expect(FileManager.default.fileExists(atPath: rig.store.microphoneURL(for: meeting.id).path))
        #expect(rig.controller.state == .idle)

        rig.engine.fails = false
        rig.controller.transcribe(meeting.id)
        await rig.controller.pendingWork?.value
        meeting = rig.store.meetings[0]
        #expect(meeting.isTranscribed && meeting.problem == nil && meeting.lines.count == 2)
    }

    @Test func aTranscribedMeetingIsNeverTranscribedAgain() async {
        let rig = rig()
        rig.settings.meetingAudio = .keep
        rig.controller.start()
        rig.controller.stop()
        await rig.controller.pendingWork?.value
        let before = rig.store.meetings[0]
        let calls = rig.engine.calls
        rig.engine.reply = { _ in "something else entirely" }
        rig.controller.transcribe(before.id)
        await rig.controller.pendingWork?.value
        #expect(rig.store.meetings[0] == before && rig.engine.calls == calls)
    }

    @Test func aSilentCallTrackLeavesANoteOnTheMeeting() async {
        let rig = rig()
        rig.audio.result = MeetingRecording(duration: 30, callWasSilent: true)
        rig.controller.start()
        rig.controller.stop()
        await rig.controller.pendingWork?.value
        #expect(rig.store.meetings[0].note?.contains("No call audio was heard") == true)
    }

    @Test func withoutTheMicrophoneNothingStartsAndTheReasonIsShown() {
        let rig = rig(microphone: false)
        rig.controller.start()
        #expect(rig.controller.state == .idle && rig.audio.started == nil)
        #expect(rig.controller.problem?.contains("Microphone access is off") == true && !rig.controller.microphoneAllowed)
        // Granted in the meantime: the next attempt reads the permission again and records.
        rig.permissions.current.microphone = true
        rig.controller.start()
        #expect(rig.controller.state.isRecording && rig.controller.problem == nil)
    }

    @Test func aRecorderThatCannotStartLeavesNothingBehind() {
        let rig = rig()
        rig.audio.failsToStart = true
        rig.controller.start()
        #expect(rig.controller.state == .idle && rig.controller.problem?.contains("Couldn’t start recording") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.store.directory.path)) ?? []).isEmpty)
    }

    @Test func discardDeletesTheRecordingAndSavesNoMeeting() {
        let rig = rig()
        rig.controller.start()
        let folder = rig.audio.started!.microphone.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.path))
        rig.controller.discard()
        #expect(rig.controller.state == .idle && rig.store.meetings.isEmpty && !FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func quittingMidMeetingKeepsTheRecordingForLater() async {
        let folder = directory()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let audio = FakeMeetingAudio(), engine = MeetingFakeEngine()
        func controller(_ store: MeetingStore) -> MeetingController {
            MeetingController(audio: audio, engine: engine, store: store, settings: settings, permissions: DemoPermissions()) { _ in MeetingFakeTrack.of([(1, false), (2, true), (1, false)]) }
        }
        let first = MeetingStore(directory: folder)
        let recording = controller(first)
        recording.start()
        recording.stopForQuit()
        #expect(recording.pendingWork == nil && engine.calls == 0)

        // Next launch: the meeting is there, not transcribed, and one click transcribes it.
        let second = MeetingStore(directory: folder)
        #expect(second.meetings.count == 1 && !second.meetings[0].isTranscribed && second.meetings[0].hasAudio)
        let later = controller(second)
        later.transcribe(second.meetings[0].id)
        await later.pendingWork?.value
        #expect(second.meetings[0].isTranscribed)
        Accent.current = .ice
    }

    @Test func askingForSystemAudioIsRememberedAndASecondStartIsIgnored() {
        let rig = rig()
        #expect(!rig.settings.askedForSystemAudio)
        rig.controller.requestSystemAudio()
        #expect(rig.audio.asked == 1 && rig.settings.askedForSystemAudio)
        rig.controller.start()
        let first = rig.controller.state
        rig.controller.start()
        #expect(rig.controller.state == first)
    }
}
