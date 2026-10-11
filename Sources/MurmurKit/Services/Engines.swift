@preconcurrency import AVFoundation
import FluidAudio
import Speech

public nonisolated struct EngineNotReady: Error, LocalizedError {
    public var errorDescription: String? { "The speech model isn’t loaded yet." }
}

/// Parakeet TDT v3 through FluidAudio. Runs on the Neural Engine; about 480 MB, downloaded once.
public final class ParakeetEngine: TranscriptionEngine {
    public let displayName = "parakeet-v3"
    /// Nil when idle; 0...1 while downloading or loading.
    public private(set) var progress: Double?
    public private(set) var lastError: String?
    private var manager: AsrManager?
    private var preparing: Task<Void, Error>?

    public init() {}

    public var isInstalled: Bool { AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3)) }
    public var isLoaded: Bool { manager != nil }

    public var readiness: EngineReadiness {
        if manager != nil { return .ready }
        if let progress { return .preparing(name: displayName, progress: progress) }
        return .unavailable(lastError ?? (isInstalled ? "The speech model is still loading. Try again in a moment." : "Download parakeet-v3 in Settings › Voice Engine, or switch to the built-in engine."))
    }

    /// Downloads if needed, then loads. Safe to call twice: the second caller waits for the first.
    public func prepare(onProgress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        if manager != nil { return }
        if let preparing { return try await preparing.value }
        progress = isInstalled ? 0.95 : 0
        lastError = nil
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: .v3) { update in
                Task { @MainActor in
                    // Leave the last few percent for loading into memory.
                    self.progress = min(update.fractionCompleted, 1) * 0.95
                    onProgress(self.progress ?? 0)
                }
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            // One short silent pass, so the first real take does not pay for warm-up.
            var state = TdtDecoderState.make()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            self.manager = manager
        }
        preparing = task
        defer {
            preparing = nil
            progress = nil
        }
        do {
            try await task.value
        } catch {
            lastError = "Couldn’t load parakeet-v3: \(error.localizedDescription)"
            throw error
        }
    }

    public func transcribe(_ clip: AudioClip) async throws -> String {
        guard let manager else { throw EngineNotReady() }
        var state = TdtDecoderState.make()
        return try await manager.transcribe(clip.samples, decoderState: &state).text
    }
}

nonisolated struct OfflineModeBlocked: LocalizedError {
    static let message = "This language needs a one-time download, and offline mode is on (Settings › Privacy)"
    var errorDescription: String? { Self.message }
}

/// Apple's on-device SpeechAnalyzer. Nothing to bundle; macOS fetches its language assets itself.
public final class AppleSpeechEngine: TranscriptionEngine {
    public let displayName = "apple-speechanalyzer"
    private let locale: @MainActor () -> Locale
    public private(set) var progress: Double?
    public private(set) var lastError: String?
    private var preparedLocale: String?
    /// True while offline mode is on: language assets are then never fetched.
    public var isOffline: @MainActor () -> Bool = { false }
    /// Called when macOS is asked to download language assets, so the request can be logged.
    public var onAssetDownload: (@MainActor () -> Void)?

    public init(locale: @escaping @MainActor () -> Locale) {
        self.locale = locale
    }

    /// True once the language files for the chosen language are known to be installed.
    public var isPrepared: Bool { preparedLocale == locale().identifier }

    public var readiness: EngineReadiness {
        if isPrepared { return .ready }
        if let progress { return .preparing(name: displayName, progress: progress) }
        // Not fatal: transcribe() prepares on demand. Reported only when a previous attempt failed.
        if let lastError { return .unavailable(lastError) }
        return .ready
    }

    /// Makes sure the language assets are installed.
    public func prepare() async throws {
        let locale = locale()
        guard preparedLocale != locale.identifier else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        lastError = nil
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard !isOffline() else { throw OfflineModeBlocked() }
                onAssetDownload?()
                progress = 0.5
                defer { progress = nil }
                try await request.downloadAndInstall()
            }
            preparedLocale = locale.identifier
        } catch {
            if error is OfflineModeBlocked {
                lastError = OfflineModeBlocked.message
                throw error
            }
            lastError = "Apple’s speech engine isn’t available for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier): \(error.localizedDescription)"
            throw error
        }
    }

    public func transcribe(_ clip: AudioClip) async throws -> String {
        try await prepare()
        let transcriber = SpeechTranscriber(locale: locale(), preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw EngineNotReady() }
        let buffer = try Self.buffer(from: clip, in: format)

        let collector = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private static func buffer(from clip: AudioClip, in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(clip.samples.count, 1))) else { throw EngineNotReady() }
        input.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress { input.floatChannelData![0].update(from: base, count: samples.count) }
        }
        if source == format { return input }
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / source.sampleRate) + 1024)
        else { throw EngineNotReady() }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}

/// Sends each take to whichever engine is selected in Settings.
public final class EngineRouter: TranscriptionEngine {
    public let parakeet: ParakeetEngine
    public let apple: AppleSpeechEngine
    private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
        parakeet = ParakeetEngine()
        apple = AppleSpeechEngine { Locale(identifier: EngineRouter.localeIdentifier(for: settings.language)) }
        apple.isOffline = { settings.offlineMode }
    }

    private var current: any TranscriptionEngine { settings.modelID == "parakeet-v3" ? parakeet : apple }

    public var displayName: String { current.displayName }
    public var readiness: EngineReadiness { current.readiness }
    public func transcribe(_ clip: AudioClip) async throws -> String { try await current.transcribe(clip) }

    static func localeIdentifier(for language: String) -> String {
        [
            "English": "en-US", "Spanish": "es-ES", "French": "fr-FR", "German": "de-DE", "Italian": "it-IT",
            "Portuguese": "pt-BR", "Dutch": "nl-NL", "Polish": "pl-PL", "Ukrainian": "uk-UA", "Russian": "ru-RU",
        ][language] ?? "en-US"
    }
}
