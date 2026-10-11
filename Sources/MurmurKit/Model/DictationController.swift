import AppKit
import Observation

/// The single state machine. UI reads this and never calls services directly.
@Observable
public final class DictationController {
    public static let levelCount = 56

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

    public var engineName: String { engine.displayName }

    @ObservationIgnored private let audio: any AudioCaptureService
    @ObservationIgnored private let engine: any TranscriptionEngine
    @ObservationIgnored private let insertion: any TextInsertionService
    @ObservationIgnored private let permissionsService: any PermissionsService
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let frontmostApp: @MainActor () -> TargetApp?
    @ObservationIgnored private let copyToClipboard: @MainActor (String) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let insertedHold: Duration
    @ObservationIgnored private let errorHold: Duration
    @ObservationIgnored private let silenceAfter: TimeInterval = 3

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
        self.frontmostApp = frontmostApp
        self.copyToClipboard = copyToClipboard
        self.now = now
        self.insertedHold = insertedHold
        self.errorHold = errorHold
        self.permissions = permissions.snapshot()
    }

    // MARK: inputs

    public func hotkey(_ event: HotkeyEvent) {
        switch (event, settings.behavior) {
        case (.cancel, _): cancel()
        case (.down, .pushToTalk): start()
        case (.up, .pushToTalk): stopAndInsert()
        case (.down, .toggle): toggle()
        case (.up, .toggle): break
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
        set(.recording(since: now()))
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

    public func refreshPermissions() {
        let fresh = permissionsService.snapshot()
        if fresh != permissions { permissions = fresh }
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
        guard let last = lastTranscription, state == .idle else { return }
        target = frontmostApp()
        let token = set(.processing)
        pendingWork = Task { await self.insert(last.text, token: token) }
    }

    public func undoLast() {
        guard let receipt = lastReceipt, canUndoLast else { return }
        canUndoLast = false
        pendingWork = Task { _ = await self.insertion.undo(receipt) }
    }

    // MARK: the take

    private func finish(_ token: Int) async {
        let text: String
        do {
            let clip = try await audio.stop()
            text = try await engine.transcribe(clip).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is ServiceUnavailable {
            return fail(.engineUnavailable("No transcription engine is connected in this build yet."), ifStill: token)
        } catch {
            return fail(.transcriptionFailed(error.localizedDescription), ifStill: token)
        }
        guard token == stateToken else { return }  // cancelled meanwhile
        guard !text.isEmpty else { return fail(.nothingHeard) }
        await insert(text, token: token)
    }

    private func insert(_ text: String, token: Int) async {
        // Checked at the last moment: the user may have tabbed into a password field while speaking.
        guard !insertion.isSecureInputActive else { return fail(.secureInput, ifStill: token) }
        let app = target?.name ?? "the front app"
        do {
            let receipt = try await insertion.insert(text)
            lastReceipt = receipt
            lastTranscription = Transcription(text: text, date: now(), appName: app)
            canUndoLast = true
            guard token == stateToken else { return }
            let words = text.split(whereSeparator: \.isWhitespace).count
            let held = set(.inserted(InsertionSummary(appName: app, wordCount: words)))
            returnToIdle(after: insertedHold, ifStill: held)
        } catch {
            // The insertion service leaves the text on the clipboard when it cannot place it.
            lastReceipt = nil
            lastTranscription = Transcription(text: text, date: now(), appName: app)
            canUndoLast = false
            fail(.insertionFailed(appName: app), ifStill: token)
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
