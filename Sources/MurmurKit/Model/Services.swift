import Foundation

public nonisolated struct AudioClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public init(samples: [Float], sampleRate: Double = 16_000) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
    public var duration: TimeInterval { Double(samples.count) / sampleRate }
}

public nonisolated enum HotkeyEvent: Sendable {
    /// The dictation shortcut went down or came up.
    case down, up
    /// A double-tap shortcut fired: start if idle, stop and insert if recording.
    case toggle
    /// Esc while recording.
    case cancel
    /// Return while recording in toggle mode: stop and insert.
    case commit
    /// ⌘C while the overlay's menu is open: stop and copy instead of inserting.
    case copy
}

public nonisolated enum HotkeyAction: Equatable, Sendable {
    case cycleMode, reinsertLast, openHistory
    /// ⌥1, ⌥2 while recording: the mode at that position in the overlay's menu.
    case selectMode(Int)
}

public nonisolated struct HotkeyBindings: Equatable, Sendable {
    public var dictation: Shortcut
    public var cycleMode: Shortcut
    public var reinsert: Shortcut
    public var history: Shortcut
    /// Toggle mode: Return ends the take.
    public var returnCommits: Bool

    public init(dictation: Shortcut, cycleMode: Shortcut, reinsert: Shortcut, history: Shortcut, returnCommits: Bool) {
        self.dictation = dictation
        self.cycleMode = cycleMode
        self.reinsert = reinsert
        self.history = history
        self.returnCommits = returnCommits
    }
}

/// Owns the event tap. Its callback only decides and enqueues; events arrive here on the main actor.
public protocol HotkeyService: AnyObject {
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
    var onAction: ((HotkeyAction) -> Void)? { get set }
    var isRunning: Bool { get }
    func start(bindings: HotkeyBindings) throws
    func update(bindings: HotkeyBindings)
    /// While recording, Esc cancels and (in toggle mode) Return commits.
    func setRecording(_ recording: Bool)
    /// While the overlay's menu is open, ⌘C copies the take instead of inserting it.
    func setOverlayMenuOpen(_ open: Bool)
    func stop()
}

public protocol AudioCaptureService: AnyObject {
    /// `onLevel` reports 0...1 roughly 20 times a second while recording.
    func start(deviceID: String?, onLevel: @escaping (Float) -> Void) throws
    func stop() async throws -> AudioClip
    func cancel()
}

public nonisolated enum EngineReadiness: Equatable, Sendable {
    case ready
    /// Downloading or loading. Progress is 0...1.
    case preparing(name: String, progress: Double)
    case unavailable(String)
}

public protocol TranscriptionEngine: AnyObject {
    var displayName: String { get }
    /// Checked before a take starts, so the user is told up front instead of losing what they said.
    var readiness: EngineReadiness { get }
    func transcribe(_ clip: AudioClip) async throws -> String
}

public extension TranscriptionEngine {
    var readiness: EngineReadiness { .ready }
}

public nonisolated struct InsertionReceipt: Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public nonisolated enum InsertionFailure: Error, Equatable {
    /// The text could not be placed; it was left on the clipboard for the user.
    case leftOnClipboard
}

public protocol TextInsertionService: AnyObject {
    /// True while a password field (or Secure Keyboard Entry) has secure input on.
    var isSecureInputActive: Bool { get }
    func insert(_ text: String) async throws -> InsertionReceipt
    /// Reverts only if the inserted text is still there unchanged. Returns whether it did.
    func undo(_ receipt: InsertionReceipt) async -> Bool
}

public nonisolated enum CleanupAvailability: Equatable, Sendable {
    case available(model: String)
    /// With a reason fit to show the user.
    case unavailable(String)

    public var isAvailable: Bool { if case .available = self { true } else { false } }
}

public nonisolated enum CleanupFailure: Error { case unavailable, tooLong, rejected }

/// Optional local cleanup of a transcript. Used by Cleaned up mode.
public protocol TextCleanupService: AnyObject {
    /// A live read: the model can be switched on or off in System Settings at any time.
    var availability: CleanupAvailability { get }
    func clean(_ text: String, instructions: String) async throws -> String
}

/// Guards against a language model that replies to the transcript instead of rewriting it.
public nonisolated enum CleanupCheck {
    /// Strips the wrappers a model sometimes adds around its reply.
    public static func tidy(_ reply: String) -> String {
        var text = reply.replacingOccurrences(of: "<transcript>", with: "").replacingOccurrences(of: "</transcript>", with: "")
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, let first = text.first, let last = text.last, "\"“".contains(first), "\"”".contains(last) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// A rewrite keeps most of the speaker's own words and stays near the original length.
    /// An answer, a refusal or an essay does not.
    public static func accepts(raw: String, cleaned: String) -> Bool {
        guard !cleaned.isEmpty, cleaned.count <= raw.count * 2 + 80 else { return false }
        let spoken = Set(words(raw))
        let written = words(cleaned).filter { $0.count > 3 }
        guard written.count >= 3 else { return true }
        let kept = written.filter(spoken.contains).count
        return Double(kept) / Double(written.count) >= 0.4
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Placeholders for the services the spike has not signed off yet. Every call
/// fails loudly so the UI shows a real error instead of pretending to work.
public final class UnavailableAudioCapture: AudioCaptureService {
    public init() {}
    public func start(deviceID: String?, onLevel: @escaping (Float) -> Void) throws { throw ServiceUnavailable() }
    public func stop() async throws -> AudioClip { throw ServiceUnavailable() }
    public func cancel() {}
}

public final class UnavailableTranscriptionEngine: TranscriptionEngine {
    public init() {}
    public let displayName = "Not installed"
    public var readiness: EngineReadiness { .unavailable("No transcription engine is connected in this build yet.") }
    public func transcribe(_ clip: AudioClip) async throws -> String { throw ServiceUnavailable() }
}

public final class UnavailableTextInsertion: TextInsertionService {
    public init() {}
    public var isSecureInputActive: Bool { false }
    public func insert(_ text: String) async throws -> InsertionReceipt { throw InsertionFailure.leftOnClipboard }
    public func undo(_ receipt: InsertionReceipt) async -> Bool { false }
}

public nonisolated struct ServiceUnavailable: Error {
    public init() {}
}
