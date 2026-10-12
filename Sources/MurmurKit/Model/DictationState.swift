import Foundation

/// The app the text is going to, captured when recording starts.
public nonisolated struct TargetApp: Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public init(name: String, bundleIdentifier: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public nonisolated struct InsertionSummary: Equatable, Sendable {
    public var appName: String
    public var wordCount: Int
    /// "Copy instead": the text went to the clipboard, not into the app.
    public var copied = false
    /// Set when the chosen AI provider did not do the clean-up: "Claude didn’t answer, cleaned up on this Mac".
    public var note: String?
}

public nonisolated struct Transcription: Equatable, Sendable {
    public var text: String
    public var date: Date
    public var appName: String
    public var mode: DictationMode = .raw
}

/// Every way a take can fail. Each one carries the words the user sees: what
/// happened, what Murmur did about it, and the one next step.
public nonisolated enum DictationError: Equatable, Sendable {
    case microphoneDenied
    case accessibilityDenied
    case inputMonitoringDenied
    case secureInput
    case nothingHeard
    case noInputDevice
    case insertionFailed(appName: String)
    case transcriptionFailed(String)
    case engineUnavailable(String)
    /// The shortcut was pressed before any speech model was ready.
    case modelNotReady(name: String, progress: Double)

    public var title: String {
        switch self {
        case .microphoneDenied: "Microphone access is off"
        case .accessibilityDenied: "Accessibility access is off"
        case .inputMonitoringDenied: "Input Monitoring is off"
        case .secureInput: "Password field: nothing was typed"
        case .nothingHeard: "Didn’t catch anything"
        case .noInputDevice: "No microphone found"
        case .insertionFailed(let app): "Couldn’t type into \(app)"
        case .transcriptionFailed: "Couldn’t transcribe that"
        case .engineUnavailable: "Dictation isn’t available"
        case .modelNotReady: "Your model is still downloading"
        }
    }

    public var message: String {
        switch self {
        case .microphoneDenied: "Murmur can’t hear you until it’s allowed in System Settings."
        case .accessibilityDenied: "Murmur can’t type for you until it’s allowed in System Settings."
        case .inputMonitoringDenied: "Your shortcut won’t work in other apps until it’s allowed in System Settings."
        case .secureInput: "macOS blocks typing into secure fields, so Murmur discarded this take. It wasn’t saved or copied."
        case .nothingHeard: "No speech was detected, so nothing was typed."
        case .noInputDevice: "Connect a microphone or pick another one in Settings, then try again."
        case .insertionFailed: "Your text is on the clipboard. Click where it should go and press ⌘V."
        case .transcriptionFailed(let reason): "Nothing was typed. \(reason)"
        case .engineUnavailable(let reason): reason
        case .modelNotReady(let name, let progress): "\(name) · \(Int(progress * 100))% downloaded. Dictation starts working as soon as it finishes."
        }
    }

    /// Amber for things the user can fix or that were handled safely; red for a take that went wrong.
    public var isWarning: Bool {
        switch self {
        case .insertionFailed, .transcriptionFailed, .engineUnavailable: false
        default: true
        }
    }
}

public nonisolated enum DictationState: Equatable, Sendable {
    case idle
    case recording(since: Date)
    case processing
    case inserted(InsertionSummary)
    case error(DictationError)

    public var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}
