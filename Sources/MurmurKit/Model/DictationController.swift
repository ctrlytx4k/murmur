import AppKit
import Observation

/// The single state machine. UI reads this and never calls services directly.
@Observable
public final class DictationController {
    public static let levelCount = 72

    public private(set) var state: DictationState = .idle
    public private(set) var permissions: PermissionSnapshot
    /// Where the text is going, captured when recording starts.
    public private(set) var target: TargetApp?
    /// Recent input levels, 0...1, newest last.
    public private(set) var levels = [Float](repeating: 0, count: DictationController.levelCount)
    /// True when the microphone has been silent for a few seconds mid-take.
    public private(set) var isSilent = false
    public private(set) var lastTranscription: Transcription?
    public private(set) var canUndoLast = false
    /// Push-to-talk only: a quick tap started this take, so it keeps recording until the shortcut is pressed again.
    public private(set) var isLatched = false
    /// A short notice shown in the overlay mid-take, such as a microphone that was unplugged.
    public private(set) var deviceNotice: String?

    public var engineName: String { engine.displayName }

    @ObservationIgnored private let audio: any AudioCaptureService
    @ObservationIgnored private let engine: any TranscriptionEngine
    @ObservationIgnored private let insertion: any TextInsertionService
    @ObservationIgnored private let permissionsService: any PermissionsService
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let cleanup: (any TextCleanupService)?
    @ObservationIgnored private let history: HistoryStore?
    @ObservationIgnored private let dictionary: DictionaryStore?
    @ObservationIgnored private let maxLengthScale: Double
    @ObservationIgnored private let tapThreshold: TimeInterval
    @ObservationIgnored private var pressedAt = Date.distantPast
    @ObservationIgnored private var recordingStarted = Date.distantPast
    @ObservationIgnored private let frontmostApp: @MainActor () -> TargetApp?
    @ObservationIgnored private let copyToClipboard: @MainActor (String) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let insertedHold: Duration
    @ObservationIgnored private let errorHold: Duration
    @ObservationIgnored private let silenceAfter: TimeInterval = 3
    @ObservationIgnored private let briefTake: TimeInterval = 1.5
    @ObservationIgnored private let doublePress: TimeInterval = 0.5

    /// Bumped on every state change so late timers and late results can tell they are stale.
    @ObservationIgnored private var stateToken = 0
    @ObservationIgnored private var lastReceipt: InsertionReceipt?
    @ObservationIgnored private var lastSoundAt = Date.distantPast
    /// The in-flight stop/transcribe/insert work. Tests await it.
    @ObservationIgnored public private(set) var pendingWork: Task<Void, Never>?

    public init(
        audio: any AudioCaptureService,
        engine: any TranscriptionEngine,
        insertion: any TextInsertionService,
        permissions: any PermissionsService,
        settings: SettingsStore,
        cleanup: (any TextCleanupService)? = nil,
        history: HistoryStore? = nil,
        dictionary: DictionaryStore? = nil,
        maxLengthScale: Double = 1,
        tapThreshold: TimeInterval = 0.4,
        frontmostApp: @escaping @MainActor () -> TargetApp? = DictationController.systemFrontmostApp,
        copyToClipboard: @escaping @MainActor (String) -> Void = DictationController.systemCopy,
        now: @escaping () -> Date = Date.init,
        insertedHold: Duration = .seconds(Tokens.Motion.insertedHold),
        errorHold: Duration = .seconds(8)
    ) {
        self.audio = audio
        self.engine = engine
        self.insertion = insertion
        self.permissionsService = permissions
        self.settings = settings
        self.cleanup = cleanup
        self.history = history
        self.dictionary = dictionary
        self.maxLengthScale = maxLengthScale
        self.tapThreshold = tapThreshold
        self.frontmostApp = frontmostApp
        self.copyToClipboard = copyToClipboard
        self.now = now
        self.insertedHold = insertedHold
        self.errorHold = errorHold
        self.permissions = permissions.snapshot()
        DebugLog.log("permissions \(Self.describe(self.permissions))")
    }

    // MARK: inputs

    public func hotkey(_ event: HotkeyEvent) {
        DebugLog.log("hotkey \(event)")
        switch (event, settings.behavior) {
        case (.cancel, _): cancel()
        case (.down, .pushToTalk):
            if state.isRecording, isLatched {
                // A second press right on the heels of the first is a double press, not a finished take.
                guard now().timeIntervalSince(recordingStarted) > doublePress else { return DebugLog.log("ignored a double press") }
                stopAndInsert()
            } else {
                pressedAt = now()
                start()
            }
        case (.up, .pushToTalk):
            // A quick tap is not a take. Keep listening hands-free until the shortcut is pressed again,
            // rather than stopping at once with nothing said.
            if state.isRecording, !isLatched, settings.doubleTapToLock, now().timeIntervalSince(pressedAt) < tapThreshold {
                isLatched = true
            } else if !isLatched {
                stopAndInsert()
            }
        case (.down, .toggle): toggle()
        case (.up, .toggle): break
        case (.commit, _): stopAndInsert()
        case (.toggle, _): toggle()
        }
    }

    public func toggle() {
        if state.isRecording { stopAndInsert() } else { start() }
    }

    public func start() {
        guard !state.isRecording, state != .processing else { return }
        refreshPermissions()
        guard permissions.microphone else { return fail(.microphoneDenied) }
        guard permissions.accessibility else { return fail(.accessibilityDenied) }
        switch engine.readiness {
        case .ready: break
        case .preparing(let name, let progress): return fail(.modelNotReady(name: name, progress: progress))
        case .unavailable(let reason): return fail(.engineUnavailable(reason))
        }

        target = frontmostApp()
        levels = [Float](repeating: 0, count: Self.levelCount)
        isSilent = false
        do {
            try audio.start(deviceID: settings.microphoneID) { [weak self] level in self?.receive(level: level) }
        } catch is ServiceUnavailable {
            return fail(.engineUnavailable("Recording isn’t connected in this build yet."))
        } catch {
            return fail(.noInputDevice)
        }
        lastSoundAt = now()
        recordingStarted = now()
        deviceNotice = nil
        let token = set(.recording(since: now()))
        // Recording stops and inserts when the maximum length is reached.
        let limit = settings.maxLength.seconds * maxLengthScale
        Task {
            try? await Task.sleep(for: .seconds(limit))
            if self.stateToken == token { self.stopAndInsert() }
        }
    }

    public func stopAndInsert() {
        guard state.isRecording else { return }
        let token = set(.processing)
        pendingWork = Task { await self.finish(token) }
    }

    /// Esc. Drops the take: nothing is transcribed, typed, saved or copied.
    public func cancel() {
        switch state {
        case .recording:
            audio.cancel()
            set(.idle)
        case .processing, .error, .inserted:
            set(.idle)
        case .idle:
            break
        }
    }

    public func dismissError() {
        if case .error = state { set(.idle) }
    }

    /// Whether Cleaned up mode can do anything right now, with the reason when it can't.
    public var cleanupAvailability: CleanupAvailability {
        cleanup?.availability ?? .unavailable("No cleanup model in this build")
    }

    public func refreshPermissions() {
        let fresh = permissionsService.snapshot()
        guard fresh != permissions else { return }
        DebugLog.log("permissions \(Self.describe(fresh))")
        permissions = fresh
    }

    public func request(_ permission: Permission) {
        permissionsService.request(permission)
    }

    // MARK: last transcription

    public func copyLast() {
        guard let lastTranscription else { return }
        copyToClipboard(lastTranscription.text)
    }

    public func reinsertLast() {
        guard let last = lastTranscription else { return }
        reinsert(last.text, mode: last.mode)
    }

    public func undoLast() {
        guard let receipt = lastReceipt, canUndoLast else { return }
        canUndoLast = false
        pendingWork = Task { _ = await self.insertion.undo(receipt) }
    }

    // MARK: the take

    private func finish(_ token: Int) async {
        let heard: String
        let seconds: Double
        do {
            let clip = try await audio.stop()
            seconds = max(clip.duration, now().timeIntervalSince(recordingStarted))
            heard = try await engine.transcribe(clip).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is ServiceUnavailable {
            return fail(.engineUnavailable("No transcription engine is connected in this build yet."), ifStill: token)
        } catch {
            return fail(.transcriptionFailed(error.localizedDescription), ifStill: token)
        }
        guard token == stateToken else { return }  // cancelled meanwhile
        guard !heard.isEmpty else {
            // A brush of the shortcut is not a take worth reporting. A longer silence still is.
            if seconds < briefTake {
                set(.idle)
                return
            }
            return fail(.nothingHeard)
        }

        // A snippet trigger replaces the whole take and skips cleanup.
        if let dictionary, let snippet = TextProcessor.snippet(for: heard, in: dictionary.snippets) {
            return await insert(TextProcessor.expand(snippet.text, now: now()), token: token, raw: nil, mode: .raw, audioSeconds: seconds)
        }
        let raw = dictionary.map { TextProcessor.applyDictionary($0.entries, to: heard, app: target?.name) } ?? heard

        // Cleanup is optional and never blocks a take: if it fails, the raw text goes in and is marked Raw.
        var text = raw
        var wasCleaned = false
        if settings.mode == .cleaned, settings.cleanupEnabled, let cleanup, let instructions = cleanupInstructions(for: target) {
            let began = now()
            do {
                text = try await cleanup.clean(raw, instructions: instructions)
                wasCleaned = true
                DebugLog.log("cleanup done in \(Int(now().timeIntervalSince(began) * 1000)) ms\(text == raw ? ", no change" : "")")
            } catch {
                // Only the kind of failure: a model error can quote the transcript.
                let kind = String(describing: error).prefix { $0 != "(" && $0 != ":" }
                DebugLog.log("cleanup failed after \(Int(now().timeIntervalSince(began) * 1000)) ms: \(type(of: error)).\(kind)")
            }
            guard token == stateToken else { return }
        }
        if settings.mode == .cleaned, text == raw, !(settings.cleanupEnabled && cleanup != nil) { DebugLog.log("cleanup skipped: switched off") }
        await insert(text, token: token, raw: text == raw ? nil : raw, mode: wasCleaned ? .cleaned : .raw, audioSeconds: seconds)
    }

    /// The cleanup instructions for a take into this app, or nil when a per-app rule says to leave it raw.
    private func cleanupInstructions(for app: TargetApp?) -> String? {
        var preset = settings.cleanupPreset
        if let rule = settings.appPresets.first(where: { $0.bundleIdentifier == app?.bundleIdentifier }) {
            guard let chosen = CleanupPreset(rawValue: rule.preset) else { return nil }
            preset = chosen
        }
        return preset == .custom ? settings.customInstructions : preset.builtInInstructions
    }

    private func insert(_ text: String, token: Int, raw: String? = nil, mode: DictationMode? = nil, audioSeconds: Double = 0) async {
        // Checked at the last moment: the user may have tabbed into a password field while speaking.
        guard !insertion.isSecureInputActive else { return fail(.secureInput, ifStill: token) }
        let app = target?.name ?? "the front app"
        let mode = mode ?? lastTranscription?.mode ?? settings.mode
        do {
            let receipt = try await insertion.insert(text)
            lastReceipt = receipt
            lastTranscription = Transcription(text: text, date: now(), appName: app, mode: mode)
            canUndoLast = true
            history?.add(
                HistoryEntry(date: now(), appName: app, bundleIdentifier: target?.bundleIdentifier, mode: mode, text: text, raw: raw, audioSeconds: audioSeconds, engine: engine.displayName),
                retention: settings.retention)
            guard token == stateToken else { return }
            let words = text.split(whereSeparator: \.isWhitespace).count
            let held = set(.inserted(InsertionSummary(appName: app, wordCount: words)))
            returnToIdle(after: insertedHold, ifStill: held)
        } catch {
            // The insertion service leaves the text on the clipboard when it cannot place it.
            lastReceipt = nil
            lastTranscription = Transcription(text: text, date: now(), appName: app, mode: mode)
            canUndoLast = false
            fail(.insertionFailed(appName: app), ifStill: token)
        }
    }

    /// Re-inserts any earlier text, from History or the dropdown.
    public func reinsert(_ text: String, mode: DictationMode) {
        guard state == .idle else { return }
        target = frontmostApp()
        let token = set(.processing)
        pendingWork = Task { await self.insert(text, token: token, mode: mode) }
    }

    /// The audio service calls this when the input device changes under a take. The notice clears itself.
    public func noteDeviceChange(_ message: String) {
        DebugLog.log("device notice: \(message)")
        deviceNotice = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.deviceNotice == message { self.deviceNotice = nil }
        }
    }

    private func receive(level: Float) {
        guard state.isRecording else { return }
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
        if level > 0.06 { lastSoundAt = now() }
        let silent = now().timeIntervalSince(lastSoundAt) > silenceAfter
        if silent != isSilent { isSilent = silent }
    }

    // MARK: transitions

    @discardableResult
    private func set(_ new: DictationState) -> Int {
        stateToken += 1
        if !new.isRecording, isLatched { isLatched = false }
        DebugLog.log("state \(Self.describe(new))")
        state = new
        return stateToken
    }

    private func fail(_ error: DictationError, ifStill token: Int? = nil) {
        if let token, token != stateToken { return }
        let held = set(.error(error))
        returnToIdle(after: errorHold, ifStill: held)
    }

    private func returnToIdle(after delay: Duration, ifStill token: Int) {
        Task {
            try? await Task.sleep(for: delay)
            if self.stateToken == token { self.set(.idle) }
        }
    }

    private static func describe(_ permissions: PermissionSnapshot) -> String {
        Permission.allCases.map { "\($0.rawValue) \(permissions.isGranted($0) ? "on" : "off")" }.joined(separator: ", ")
    }

    /// State name for the debug log, without any transcript text.
    private static func describe(_ state: DictationState) -> String {
        switch state {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .inserted(let summary): "inserted (\(summary.wordCount) words)"
        case .error(let error): "error: \(error.title)"
        }
    }

    // MARK: previews

    /// Puts the controller in a fixed state without touching any service.
    /// For design snapshots and the demo mode only.
    func loadPreview(
        state: DictationState, target: TargetApp? = nil, levels: [Float]? = nil, isSilent: Bool = false,
        last: Transcription? = nil, canUndo: Bool = false, permissions: PermissionSnapshot? = nil, deviceNotice: String? = nil
    ) {
        self.deviceNotice = deviceNotice
        set(state)
        self.target = target
        if let levels { self.levels = levels }
        self.isSilent = isSilent
        lastTranscription = last
        canUndoLast = canUndo
        if let permissions { self.permissions = permissions }
    }

    // MARK: system defaults

    public static func systemFrontmostApp() -> TargetApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return TargetApp(name: app.localizedName ?? "the front app", bundleIdentifier: app.bundleIdentifier)
    }

    public static func systemCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
