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

public nonisolated enum HotkeyEvent: Sendable { case down, up, cancel }

/// Owns the event tap. Its callback only enqueues; events arrive here on the main actor.
public protocol HotkeyService: AnyObject {
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
    func start(shortcut: Shortcut) throws
    func stop()
}

public protocol AudioCaptureService: AnyObject {
    /// `onLevel` reports 0...1 roughly 20 times a second while recording.
    func start(deviceID: String?, onLevel: @escaping (Float) -> Void) throws
    func stop() async throws -> AudioClip
    func cancel()
}

public protocol TranscriptionEngine: AnyObject {
    var displayName: String { get }
    func transcribe(_ clip: AudioClip) async throws -> String
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
