import Foundation
import Observation

/// The state machine for recording a meeting: idle, recording, transcribing. Separate from dictation,
/// which keeps working during a call. The Meetings tab reads this and never calls a service itself.
@Observable
public final class MeetingController {
    public enum State: Equatable {
        case idle
        case recording(since: Date)
        /// Progress is 0...1.
        case transcribing(id: UUID, progress: Double)

        public var isRecording: Bool { if case .recording = self { true } else { false } }
        public var isIdle: Bool { self == .idle }
    }

    public private(set) var state = State.idle
    /// The microphone's level while recording, 0...1.
    public private(set) var level: Float = 0
    /// Why the last attempt to start did not work. Shown until the next attempt.
    public private(set) var problem: String?
    /// The meeting that most recently stopped recording, so the window can open it.
    public private(set) var latest: UUID?
    /// Checked when the tab is shown. Never cached.
    public private(set) var microphoneAllowed: Bool
    /// True during the first part of transcribing a call, while the voices on it are being told apart.
    public private(set) var isSeparatingSpeakers = false
    /// Paused: nothing is being recorded until it is resumed.
    public private(set) var isPaused = false
    /// Your microphone is left out; the call is still recorded.
    public private(set) var isMuted = false
    /// How many moments have been marked in this recording.
    public private(set) var markCount = 0
    /// A call app that just started using the microphone, waiting for "Record" or "Not Now".
    public private(set) var detectedCall: CallApp?

    @ObservationIgnored private let audio: any MeetingAudioService
    @ObservationIgnored private let engine: any TranscriptionEngine
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let permissions: any PermissionsService
    @ObservationIgnored private let openTrack: (URL) -> any MeetingTrack
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let separator: (any SpeakerSeparator)?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var recordingCall = false
    @ObservationIgnored private var marks: [Double] = []
    @ObservationIgnored private var callApps: Set<String> = []
    @ObservationIgnored private var declinedCalls: Set<String> = []
    /// The transcription in flight. Tests await it.
    @ObservationIgnored public private(set) var pendingWork: Task<Void, Never>?

    public init(
        audio: any MeetingAudioService, engine: any TranscriptionEngine, store: MeetingStore, settings: SettingsStore,
        permissions: any PermissionsService, separator: (any SpeakerSeparator)? = nil,
        openTrack: @escaping (URL) -> any MeetingTrack = { AudioFileTrack(url: $0) }, now: @escaping () -> Date = Date.init
    ) {
        self.separator = separator
        self.audio = audio
        self.engine = engine
        self.store = store
        self.settings = settings
        self.permissions = permissions
        self.openTrack = openTrack
        self.now = now
        microphoneAllowed = permissions.snapshot().microphone
    }

    public func refreshPermissions() {
        let allowed = permissions.snapshot().microphone
        if allowed != microphoneAllowed { microphoneAllowed = allowed }
    }

    public func requestMicrophone() { permissions.request(.microphone) }

    /// Shows the macOS prompt for System Audio Recording. macOS does not tell an app what was answered,
    /// so the only thing remembered is that it was asked.
    public func requestSystemAudio() {
        audio.requestSystemAudio()
        settings.askedForSystemAudio = true
    }

    public func start() {
        guard state.isIdle else { return }
        refreshPermissions()
        guard microphoneAllowed else {
            problem = "Microphone access is off. Allow it below, then start again."
            return
        }
        let id = UUID()
        let withCall = settings.meetingSource == .microphoneAndCall
        do {
            try store.prepareFolder(for: id)
            try audio.start(
                microphone: store.microphoneURL(for: id), call: withCall ? store.callURL(for: id) : nil,
                microphoneID: settings.microphoneID
            ) { [weak self] level in
                guard let self, !self.isPaused, !self.isMuted else { return }
                self.level = level
            }
        } catch {
            try? FileManager.default.removeItem(at: store.folder(for: id))
            problem = "Couldn’t start recording: \(error.localizedDescription)"
            DebugLog.log("meeting: start failed, \(error)")
            return
        }
        if withCall { settings.askedForSystemAudio = true }
        problem = nil
        recordingID = id
        recordingCall = withCall
        marks = []
        markCount = 0
        isPaused = false
        isMuted = false
        detectedCall = nil
        state = .recording(since: now())
        DebugLog.log("meeting: recording, call audio \(withCall)")
    }

    /// The meeting shortcut: start when idle, stop and transcribe when recording.
    public func toggle() {
        if state.isRecording { stop() } else { start() }
    }

    public func togglePause() {
        guard state.isRecording else { return }
        isPaused.toggle()
        audio.setPaused(isPaused)
        if isPaused { level = 0 }
        DebugLog.log("meeting: \(isPaused ? "paused" : "resumed")")
    }

    public func toggleMute() {
        guard state.isRecording else { return }
        isMuted.toggle()
        audio.setMicrophoneMuted(isMuted)
        if isMuted { level = 0 }
        DebugLog.log("meeting: microphone \(isMuted ? "muted" : "unmuted")")
    }

    /// Mark this moment: the line being said is flagged in the transcript.
    public func mark() {
        guard case .recording(let since) = state else { return }
        marks.append(max(0, now().timeIntervalSince(since)))
        markCount = marks.count
    }

    // MARK: a call starts

    /// Told, every few seconds, which apps are using the microphone. A call app that has just started is offered
    /// for recording once; "Not Now" holds until that app lets go of the microphone.
    public func microphoneUsers(_ bundleIdentifiers: Set<String>) {
        let apps = Set(bundleIdentifiers.compactMap { CallApp.matching($0)?.bundleIdentifier })
        let started = apps.subtracting(callApps)
        // A call that starts while the last meeting is still being transcribed is not forgotten: it is offered once that is done.
        if case .transcribing = state { callApps.formIntersection(apps) } else { callApps = apps }
        declinedCalls.formIntersection(apps)
        if let waiting = detectedCall, !apps.contains(waiting.bundleIdentifier) { detectedCall = nil }
        guard settings.askWhenCallStarts, state.isIdle, detectedCall == nil else { return }
        // A real call app is offered ahead of a browser that happens to start listening at the same moment.
        let fresh = started.subtracting(declinedCalls).compactMap(CallApp.matching).sorted { !$0.isBrowser && $1.isBrowser }
        guard let app = fresh.first else { return }
        if settings.alwaysRecordApps.contains(app.bundleIdentifier) {
            DebugLog.log("meeting: \(app.name) started a call, recording as always")
            start()
        } else {
            detectedCall = app
        }
    }

    /// "Record", or "Always for Zoom".
    public func recordDetectedCall(always: Bool = false) {
        guard let app = detectedCall else { return }
        if always, !settings.alwaysRecordApps.contains(app.bundleIdentifier) { settings.alwaysRecordApps.append(app.bundleIdentifier) }
        detectedCall = nil
        start()
    }

    /// "Not Now": no more asking for this call.
    public func dismissDetectedCall() {
        guard let app = detectedCall else { return }
        declinedCalls.insert(app.bundleIdentifier)
        detectedCall = nil
    }

    /// Stop & Transcribe. The meeting is saved first, so a failed transcription never loses the recording.
    public func stop() {
        guard let id = finishRecording() else { return }
        transcribe(id)
    }

    /// Called when the app quits mid-meeting: the recording is kept and can be transcribed next time.
    public func stopForQuit() {
        _ = finishRecording()
    }

    /// Throws the recording in progress away.
    public func discard() {
        guard case .recording = state, let id = recordingID else { return }
        _ = audio.stop()
        try? FileManager.default.removeItem(at: store.folder(for: id))
        recordingID = nil
        level = 0
        isPaused = false
        isMuted = false
        state = .idle
        DebugLog.log("meeting: discarded")
    }

    private func finishRecording() -> UUID? {
        guard case .recording(let since) = state, let id = recordingID else { return nil }
        let recording = audio.stop()
        recordingID = nil
        level = 0
        let title = "Meeting, \(since.formatted(date: .omitted, time: .shortened))"
        var meeting = Meeting(id: id, title: title, date: since, duration: recording.duration, includesCallAudio: recordingCall)
        if !marks.isEmpty { meeting.marks = marks }
        // Kept on the meeting, so it is still said when the transcript is made after a quit or a failed attempt.
        if recording.callWasSilent { meeting.callWasSilent = true }
        store.add(meeting)
        isPaused = false
        isMuted = false
        latest = id
        state = .idle
        DebugLog.log("meeting: stopped after \(Int(recording.duration)) s, call silent \(recording.callWasSilent)")
        return id
    }

    /// Transcribes a meeting that has audio and no transcript: straight after Stop, or later after a failure.
    public func transcribe(_ id: UUID) {
        guard state.isIdle, let meeting = store.meeting(id), !meeting.isTranscribed, meeting.hasAudio else { return }
        state = .transcribing(id: id, progress: 0)
        let callWasSilent = meeting.callWasSilent == true
        pendingWork = Task { [weak self] in
            guard let self else { return }
            do {
                let files = FileManager.default
                let microphoneURL = self.store.microphoneURL(for: id), callURL = self.store.callURL(for: id)
                let microphone = files.fileExists(atPath: microphoneURL.path) ? self.openTrack(microphoneURL) : nil
                let call = meeting.includesCallAudio && files.fileExists(atPath: callURL.path) ? self.openTrack(callURL) : nil
                guard microphone != nil || call != nil else { throw MeetingTranscriptionFailure(message: "The recording’s audio is missing.") }
                // Who spoke when on the call. Optional: without it, or if it fails, the call is one "Others".
                var turns: [SpeakerTurn]?
                if call != nil, !callWasSilent, self.settings.meetingSpeakers, let separator = self.separator, separator.isInstalled {
                    self.isSeparatingSpeakers = true
                    do {
                        turns = try await separator.turns(in: callURL)
                        DebugLog.log("meeting: \(Set((turns ?? []).map(\.voice)).count) voices on the call")
                    } catch {
                        DebugLog.log("meeting: could not tell the speakers apart, \(error)")
                    }
                    self.isSeparatingSpeakers = false
                }
                let result = try await MeetingTranscriber.transcribe(
                    microphone: microphone, call: call, callWasSilent: callWasSilent, callTurns: turns, engine: self.engine
                ) { [weak self] progress in
                    self?.state = .transcribing(id: id, progress: progress)
                }
                self.store.finishTranscription(id, lines: result.lines, engine: self.engine.displayName, note: result.note)
                // The audio has done its job. It stays only if Settings says to keep it.
                if self.settings.meetingAudio == .delete { self.store.deleteAudio(id) }
                DebugLog.log("meeting: transcribed, \(result.lines.count) lines")
            } catch {
                // The audio is kept whatever the setting, so it can be tried again.
                self.store.markFailed(id, problem: error.localizedDescription)
                DebugLog.log("meeting: transcription failed, \(error)")
            }
            self.isSeparatingSpeakers = false
            self.state = .idle
        }
    }
}
