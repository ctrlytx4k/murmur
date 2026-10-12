import FluidAudio
import Foundation

/// Holds the diarizer off the main actor. Its models are only written while loading.
private nonisolated final class DiarizerBox: @unchecked Sendable {
    private let manager = OfflineDiarizerManager()

    func prepare() async throws { try await manager.prepareModels() }

    func turns(in track: URL) async throws -> [SpeakerTurn] {
        try await manager.prepareModels()
        let result = try await manager.process(track)
        // The library names its speakers "S1", "S2", …
        var numbers: [String: Int] = [:]
        return result.segments.map { segment in
            let voice = numbers[segment.speakerId] ?? numbers.count + 1
            numbers[segment.speakerId] = voice
            return SpeakerTurn(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds), voice: voice)
        }
    }
}

/// Tells speakers apart with the pyannote Community-1 pipeline, converted to Core ML by FluidInference.
/// About 22 MB, downloaded once; after that it runs on this Mac.
@Observable
public final class FluidSpeakerSeparator: SpeakerSeparator {
    public enum Status: Equatable { case notInstalled, downloading, installed, failed(String) }

    public private(set) var status: Status
    @ObservationIgnored private let box = DiarizerBox()
    /// True while offline mode is on: the model is then never fetched.
    @ObservationIgnored public var isOffline: @MainActor () -> Bool = { false }
    /// Called when the download starts, so it can go in the network log.
    @ObservationIgnored public var onDownload: (@MainActor () -> Void)?

    public init() {
        status = Self.filesExist ? .installed : .notInstalled
    }

    public var isInstalled: Bool { status == .installed }

    private static var filesExist: Bool {
        let folder = OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Downloads the model if it is missing and loads it.
    public func download() async {
        guard status != .downloading, status != .installed else { return }
        guard !isOffline() else {
            status = .failed("Offline mode is on (Settings › Privacy)")
            return
        }
        status = .downloading
        onDownload?()
        do {
            try await box.prepare()
            status = .installed
        } catch {
            status = .failed("Couldn’t download the speaker model: \(error.localizedDescription)")
        }
    }

    public func turns(in track: URL) async throws -> [SpeakerTurn] {
        try await box.turns(in: track)
    }
}
