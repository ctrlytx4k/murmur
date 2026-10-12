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
    var paused = false
    var muted = false
    func setPaused(_ paused: Bool) { self.paused = paused }
    func setMicrophoneMuted(_ muted: Bool) { self.muted = muted }
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

    // MARK: pause, mute, mark

    @Test func pauseAndMuteReachTheRecorderAndResetForTheNextMeeting() async {
        let rig = rig()
        // Nothing to pause before a recording.
        rig.controller.togglePause()
        #expect(!rig.controller.isPaused && !rig.audio.paused)
        rig.controller.start()
        rig.controller.togglePause()
        #expect(rig.controller.isPaused && rig.audio.paused && rig.controller.state.isRecording)
        rig.controller.togglePause()
        #expect(!rig.controller.isPaused && !rig.audio.paused)
        rig.controller.toggleMute()
        #expect(rig.controller.isMuted && rig.audio.muted && !rig.audio.paused)
        rig.controller.stop()
        await rig.controller.pendingWork?.value
        #expect(!rig.controller.isMuted && !rig.controller.isPaused)
        rig.controller.start()
        #expect(!rig.controller.isMuted && !rig.controller.isPaused && rig.controller.markCount == 0)
    }

    @Test func aMarkedMomentFlagsTheLineBeingSaid() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        let store = MeetingStore(directory: directory())
        let controller = MeetingController(
            audio: FakeMeetingAudio(), engine: MeetingFakeEngine(), store: store, settings: settings, permissions: DemoPermissions(),
            openTrack: { url in url.lastPathComponent == "call.caf" ? MeetingFakeTrack.of([(5, false), (2, true), (1, false)]) : MeetingFakeTrack.of([(1, false), (2, true), (5, false)]) },
            now: { clock })
        controller.mark()
        #expect(controller.markCount == 0)
        controller.start()
        // Six seconds in, while the call is speaking (it starts at about 5 s).
        clock = clock.addingTimeInterval(6)
        controller.mark()
        #expect(controller.markCount == 1)
        controller.stop()
        await controller.pendingWork?.value
        let meeting = store.meetings[0]
        #expect(meeting.marks == [6] && meeting.lines.count == 2)
        #expect(meeting.markedLines == [meeting.lines[1].id])
        // The mark is a flag beside the transcript: the words are as transcribed.
        #expect(meeting.lines[1].text.hasPrefix("um so"))
        Accent.current = .ice
    }

    @Test func theShortcutStartsThenStopsAndTranscribes() async {
        let rig = rig()
        rig.controller.toggle()
        #expect(rig.controller.state.isRecording)
        rig.controller.toggle()
        await rig.controller.pendingWork?.value
        #expect(rig.controller.state == .idle && rig.store.meetings.count == 1 && rig.store.meetings[0].isTranscribed)
        #expect(SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!).hotkeyBindings.meeting == HotkeyBindings.defaultMeeting)
        Accent.current = .ice
    }

    // MARK: a call starts

    @Test func aCallAppStartingToListenIsOfferedOnce() {
        let rig = rig()
        rig.controller.microphoneUsers([])
        #expect(rig.controller.detectedCall == nil)
        // Zoom's helper process opens the microphone.
        rig.controller.microphoneUsers(["us.zoom.xos.helper", "com.example.dictaphone"])
        #expect(rig.controller.detectedCall == CallApp(bundleIdentifier: "us.zoom.xos", name: "Zoom", isBrowser: false))
        #expect(rig.controller.state == .idle && rig.audio.started == nil)
        // "Not Now" holds for the rest of that call, and the next call is offered again.
        rig.controller.dismissDetectedCall()
        rig.controller.microphoneUsers(["us.zoom.xos.helper"])
        #expect(rig.controller.detectedCall == nil)
        rig.controller.microphoneUsers([])
        rig.controller.microphoneUsers(["us.zoom.xos"])
        #expect(rig.controller.detectedCall?.name == "Zoom")
        // The call ends before an answer: the offer goes away.
        rig.controller.microphoneUsers([])
        #expect(rig.controller.detectedCall == nil)
    }

    @Test func recordStartsTheMeetingAndAlwaysIsRemembered() {
        let rig = rig()
        rig.controller.microphoneUsers(["com.microsoft.teams2"])
        rig.controller.recordDetectedCall()
        #expect(rig.controller.state.isRecording && rig.controller.detectedCall == nil && rig.settings.alwaysRecordApps.isEmpty)
        rig.controller.discard()
        rig.controller.microphoneUsers([])

        rig.controller.microphoneUsers(["com.microsoft.teams2"])
        rig.controller.recordDetectedCall(always: true)
        #expect(rig.settings.alwaysRecordApps == ["com.microsoft.teams"])
        rig.controller.discard()
        rig.controller.microphoneUsers([])
        // From now on a Teams call records without asking.
        rig.controller.microphoneUsers(["com.microsoft.teams2"])
        #expect(rig.controller.state.isRecording && rig.controller.detectedCall == nil)
    }

    @Test func nothingIsOfferedWhenAskingIsOffOrWhileAlreadyRecording() {
        let off = rig()
        off.settings.askWhenCallStarts = false
        off.controller.microphoneUsers(["us.zoom.xos"])
        #expect(off.controller.detectedCall == nil && off.controller.state == .idle)

        let busy = rig()
        busy.controller.start()
        busy.controller.microphoneUsers(["us.zoom.xos"])
        #expect(busy.controller.detectedCall == nil)

        // A browser is named for what is known: it is using the microphone. A call app wins over it.
        let both = rig()
        both.controller.microphoneUsers(["com.google.Chrome.helper", "com.tinyspeck.slackmacgap.helper"])
        #expect(both.controller.detectedCall?.name == "Slack")
        #expect(CallApp.matching("com.google.Chrome.helper")?.isBrowser == true && CallApp.matching("com.apple.Notes") == nil)
    }

    // MARK: echo

    @Test func aYouLineThatOnlyRepeatsTheCallIsLeftOutAndSaidSo() async throws {
        #expect(EchoFilter.isEcho(microphone: "yes the language step is good but", call: "Yes. The language step is good, but the engine step feels heavy."))
        #expect(!EchoFilter.isEcho(microphone: "I disagree, we should ship on Friday instead", call: "Yes. The language step is good, but the engine step feels heavy."))
        // Short agreement is never treated as echo.
        #expect(!EchoFilter.isEcho(microphone: "Yes, okay.", call: "Yes, okay."))

        final class Scripted: TranscriptionEngine {
            let displayName = "scripted"
            // The clip's first sample is its start time (see MeetingFakeTrack).
            func transcribe(_ clip: AudioClip) async throws -> String {
                switch Int((clip.samples.first ?? 0).rounded()) {
                case 1: "I think we should start with onboarding today"
                case 5, 6: "the engine step feels heavy for new users"
                default: "sounds good to me let us do that"
                }
            }
        }
        // The microphone hears you at 1 s, then the speakers at about 6 s, then you again at 12 s.
        let result = try await MeetingTranscriber.transcribe(
            microphone: MeetingFakeTrack.of([(1, false), (2, true), (3, false), (2, true), (4, false), (2, true), (1, false)]),
            call: MeetingFakeTrack.of([(5, false), (3, true), (7, false)]), engine: Scripted(), onProgress: { _ in })
        #expect(result.lines.map(\.speaker) == [.you, .others, .you])
        #expect(result.lines.map(\.text) == ["I think we should start with onboarding today", "the engine step feels heavy for new users", "sounds good to me let us do that"])
        #expect(result.note?.hasPrefix("1 line your microphone picked up from the speakers was left out") == true)
    }

    @Test func aReplyMadeOfTheSameSmallWordsIsNotAnEcho() {
        let monologue = "I think the plan is fine and that is what we said last week, so it is right to do the onboarding first and then I can look at the engine step"
        // Nearly every word was also said on the call, but not in this order: it is a reply, not the speakers.
        #expect(!EchoFilter.isEcho(microphone: "Yeah, I think it is right, that is the plan to do", call: monologue))
        // The real thing, with a word misheard and a word lost on the way across the room.
        #expect(EchoFilter.isEcho(microphone: "the plan is fine and that is what we set last week so it is right to the onboarding first", call: monologue))
    }

    @Test func aLineSaidInTheCallsSilenceIsKeptEvenWhenItRepeatsTheCall() async throws {
        #expect(EchoFilter.overlap(of: 2...4, with: [0...3]) == 0.5)
        #expect(EchoFilter.overlap(of: 2...4, with: [0...3, 2.5...3.5, 3.5...10]) == 1)
        #expect(EchoFilter.overlap(of: 2...4, with: [5...6]) == 0)
        // Only the words of a long turn that were being said at that moment count.
        #expect(EchoFilter.said("one two three four five six seven eight nine ten", over: 0...20, during: 4...8) == "three four")

        final class Parrot: TranscriptionEngine {
            let displayName = "parrot"
            func transcribe(_ clip: AudioClip) async throws -> String { "so the deadline is Friday the tenth then" }
        }
        // The call says it from 1 s to 4 s; you read it back straight afterwards. Both are kept.
        let result = try await MeetingTranscriber.transcribe(
            microphone: MeetingFakeTrack.of([(4.4, false), (3, true), (1, false)]),
            call: MeetingFakeTrack.of([(1, false), (3, true), (4.4, false)]), engine: Parrot(), onProgress: { _ in })
        #expect(result.lines.map(\.speaker) == [.others, .you])
        #expect(result.note == nil)
    }

    // MARK: speakers

    @Test func turnsAreJoinedTidiedAndNumberedInOrderOfFirstSpeaking() {
        let pieces = SpeakerTurns.pieces([
            SpeakerTurn(start: 20, end: 24, voice: 7),
            SpeakerTurn(start: 5, end: 8, voice: 3),
            // The same voice after a short breath: one turn.
            SpeakerTurn(start: 8.3, end: 10, voice: 3),
            // Too short to hold a word.
            SpeakerTurn(start: 12, end: 12.1, voice: 9),
            SpeakerTurn(start: 30, end: 31, voice: 3),
        ])
        #expect(pieces == [
            SpeakerTurn(start: 5, end: 10, voice: 1), SpeakerTurn(start: 20, end: 24, voice: 2), SpeakerTurn(start: 30, end: 31, voice: 1),
        ])
        // A long monologue is cut into pieces the engine can take, all by the same voice.
        let long = SpeakerTurns.pieces([SpeakerTurn(start: 0, end: 60, voice: 4)])
        #expect(long.count == 3 && long.allSatisfy { $0.voice == 1 && $0.end - $0.start <= SpeechSegmenter.longest })
        #expect(long.first?.start == 0 && long.last?.end == 60)
        #expect(SpeakerTurns.pieces([]).isEmpty)
    }

    @Test func withTurnsEachLineCarriesItsVoiceAndWithoutThemTheCallIsOthers() async throws {
        let call = MeetingFakeTrack.of([(5, false), (2, true), (1, false), (2, true)])
        let turns = [SpeakerTurn(start: 5, end: 7, voice: 1), SpeakerTurn(start: 8, end: 10, voice: 2)]
        let told = try await MeetingTranscriber.transcribe(
            microphone: MeetingFakeTrack.of([(1, false), (2, true), (7, false)]), call: call, callTurns: turns, engine: MeetingFakeEngine(), onProgress: { _ in })
        #expect(told.lines.map(\.speaker) == [.you, .others, .others] && told.lines.map(\.voice) == [nil, 1, 2])
        let untold = try await MeetingTranscriber.transcribe(
            microphone: nil, call: call, callTurns: nil, engine: MeetingFakeEngine(), onProgress: { _ in })
        #expect(untold.lines.count == 2 && untold.lines.allSatisfy { $0.speaker == .others && $0.voice == nil })
    }

    @Test func namingASpeakerChangesTheLabelAndNeverTheWords() {
        let store = MeetingStore(directory: directory())
        var meeting = Meeting(title: "Sync", date: Date(), duration: 60, includesCallAudio: true)
        let raw = [
            MeetingLine(start: 1, speaker: .you, text: "um hello"), MeetingLine(start: 3, speaker: .others, voice: 1, text: "hi there"),
            MeetingLine(start: 5, speaker: .others, voice: 2, text: "morning"), MeetingLine(start: 7, speaker: .others, text: "unknown voice"),
        ]
        meeting.setTranscript(raw, engine: "fake")
        store.add(meeting)
        #expect(raw.map { store.meeting(meeting.id)!.label(for: $0) } == ["You", "Speaker 1", "Speaker 2", "Others"])
        #expect(store.meeting(meeting.id)?.voiceCount == 2)
        store.nameSpeaker(meeting.id, voice: 1, "  Priya ")
        var stored = store.meeting(meeting.id)!
        #expect(raw.map { stored.label(for: $0) } == ["You", "Priya", "Speaker 2", "Others"] && stored.lines == raw)
        #expect(stored.text { _ in "9:00" }.contains("9:00 Priya: hi there"))
        // Survives a relaunch, and an empty name goes back to the number.
        #expect(MeetingStore(directory: store.directory).meetings[0].speakerNames == ["1": "Priya"])
        store.nameSpeaker(meeting.id, voice: 1, "")
        stored = store.meeting(meeting.id)!
        #expect(stored.label(for: raw[1]) == "Speaker 1" && stored.speakerNames == nil && stored.lines == raw)
    }

    @MainActor private final class FakeSeparator: SpeakerSeparator {
        var isInstalled = true
        var fails = false
        var asked = 0
        struct Broken: Error {}
        func turns(in track: URL) async throws -> [SpeakerTurn] {
            asked += 1
            if fails { throw Broken() }
            return [SpeakerTurn(start: 5, end: 7, voice: 1)]
        }
    }

    private func separated(_ separator: FakeSeparator, settings change: (SettingsStore) -> Void = { _ in }) async -> Meeting {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")!)
        change(settings)
        let store = MeetingStore(directory: directory())
        let controller = MeetingController(
            audio: FakeMeetingAudio(), engine: MeetingFakeEngine(), store: store, settings: settings, permissions: DemoPermissions(), separator: separator
        ) { url in
            url.lastPathComponent == "call.caf" ? MeetingFakeTrack.of([(5, false), (2, true), (1, false)]) : MeetingFakeTrack.of([(1, false), (2, true), (5, false)])
        }
        controller.start()
        controller.stop()
        await controller.pendingWork?.value
        Accent.current = .ice
        #expect(!controller.isSeparatingSpeakers && controller.state == .idle)
        return store.meetings[0]
    }

    @Test func aCallIsToldApartWhenTheModelIsThereAndTheSettingIsOn() async {
        let separator = FakeSeparator()
        let meeting = await separated(separator)
        #expect(separator.asked == 1 && meeting.lines.map(\.voice) == [nil, 1] && meeting.voiceCount == 1)
    }

    @Test func withoutTheModelOrWithTheSettingOffOrOnFailureTheCallIsStillTranscribed() async {
        let missing = FakeSeparator()
        missing.isInstalled = false
        var meeting = await separated(missing)
        #expect(missing.asked == 0 && meeting.isTranscribed && meeting.lines.map(\.speaker) == [.you, .others] && meeting.voiceCount == 0)

        let off = FakeSeparator()
        meeting = await separated(off) { $0.meetingSpeakers = false }
        #expect(off.asked == 0 && meeting.isTranscribed && meeting.voiceCount == 0)

        let broken = FakeSeparator()
        broken.fails = true
        meeting = await separated(broken)
        #expect(broken.asked == 1 && meeting.isTranscribed && meeting.lines.count == 2 && meeting.voiceCount == 0)
    }

    @Test func anExportCarriesTheSummaryThenTheTranscriptExactlyAsStored() {
        var meeting = Meeting(title: "Design review", date: Date(), duration: 60, includesCallAudio: true)
        meeting.setTranscript([
            MeetingLine(start: 1, speaker: .you, text: "um so hello"), MeetingLine(start: 3, speaker: .others, voice: 1, text: "hi there"),
        ], engine: "fake")
        meeting.speakerNames = ["1": "Priya"]
        let plain = meeting.export(markdown: false, day: "Today") { _ in "9:31" }
        #expect(plain == "Design review\n\nToday\n\nTRANSCRIPT\n\n9:31 You: um so hello\n9:31 Priya: hi there\n")
        meeting.summary = MeetingSummary(text: "Key points\n- one", provider: "Apple Intelligence", isLocal: true, date: Date())
        let markdown = meeting.export(markdown: true, day: "Today") { _ in "9:31" }
        #expect(markdown.hasPrefix("# Design review\n\nToday\n\n## Summary\n\n**Key points**\n- one\n\n_Summary by Apple Intelligence · on this Mac_\n\n## Transcript\n\n"))
        #expect(markdown.hasSuffix("- 9:31 **You:** um so hello\n- 9:31 **Priya:** hi there\n"))
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

    @Test func theSilentCallIsStillSaidWhenTheTranscriptIsMadeAfterARelaunch() async {
        let rig = rig()
        rig.audio.result = MeetingRecording(duration: 30, callWasSilent: true)
        rig.controller.start()
        rig.controller.stopForQuit()
        #expect(rig.store.meetings[0].callWasSilent == true)

        let store = MeetingStore(directory: rig.store.directory)
        let later = MeetingController(audio: rig.audio, engine: rig.engine, store: store, settings: rig.settings, permissions: rig.permissions) { _ in
            MeetingFakeTrack.of([(1, false), (2, true), (1, false)])
        }
        later.transcribe(store.meetings[0].id)
        await later.pendingWork?.value
        #expect(store.meetings[0].isTranscribed && store.meetings[0].note?.contains("No call audio was heard") == true)
    }

    @Test func aMeetingSavedBeforeTheSilentFlagExistedStillLoads() throws {
        let old = """
        {"date":771000000,"duration":12,"hasAudio":true,"id":"6F0B2B0A-0000-4000-8000-000000000001","includesCallAudio":true,"isTranscribed":false,"lines":[],"title":"Old meeting"}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(old.utf8))
        #expect(meeting.title == "Old meeting" && meeting.callWasSilent == nil && meeting.marks == nil && meeting.speakerNames == nil)
    }

    @Test func aCallThatStartsWhileTranscribingIsOfferedOnceThatIsDone() async {
        let rig = rig()
        rig.controller.start()
        rig.controller.stop()
        #expect(!rig.controller.state.isIdle)
        rig.controller.microphoneUsers(["us.zoom.xos"])
        #expect(rig.controller.detectedCall == nil)
        await rig.controller.pendingWork?.value
        rig.controller.microphoneUsers(["us.zoom.xos"])
        #expect(rig.controller.detectedCall?.name == "Zoom")
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
