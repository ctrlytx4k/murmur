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
    @ObservationIgnored private var silentCalls: Set<UUID> = []
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
            ) { [weak self] level in self?.level = level }
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
        state = .recording(since: now())
        DebugLog.log("meeting: recording, call audio \(withCall)")
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
        state = .idle
        DebugLog.log("meeting: discarded")
    }

    private func finishRecording() -> UUID? {
        guard case .recording(let since) = state, let id = recordingID else { return nil }
        let recording = audio.stop()
        recordingID = nil
        level = 0
        if recording.callWasSilent { silentCalls.insert(id) }
        let title = "Meeting, \(since.formatted(date: .omitted, time: .shortened))"
        store.add(Meeting(id: id, title: title, date: since, duration: recording.duration, includesCallAudio: recordingCall))
        latest = id
        state = .idle
        DebugLog.log("meeting: stopped after \(Int(recording.duration)) s, call silent \(recording.callWasSilent)")
        return id
    }

    /// Transcribes a meeting that has audio and no transcript: straight after Stop, or later after a failure.
    public func transcribe(_ id: UUID) {
        guard state.isIdle, let meeting = store.meeting(id), !meeting.isTranscribed, meeting.hasAudio else { return }
        state = .transcribing(id: id, progress: 0)
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
                if call != nil, !self.silentCalls.contains(id), self.settings.meetingSpeakers, let separator = self.separator, separator.isInstalled {
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
                    microphone: microphone, call: call, callWasSilent: self.silentCalls.contains(id), callTurns: turns, engine: self.engine
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
