import AVFoundation
import Observation

public nonisolated struct InputDevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var systemDefaultName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    /// The name to show for a stored choice; falls back to the system default when the device is gone.
    static func displayName(for id: String?) -> String {
        if let id, let match = inputs().first(where: { $0.id == id }) { return match.name }
        return systemDefaultName ?? "No microphone"
    }
}

/// A live input meter for onboarding, so "the meter should move" is true.
/// Only runs while that step is on screen.
@Observable
final class MicLevelMonitor {
    static let barCount = 12
    private(set) var levels = [Float](repeating: 0, count: MicLevelMonitor.barCount)
    @ObservationIgnored private var engine: AVAudioEngine?

    func start() {
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap { [weak self] level in
            Task { @MainActor in self?.push(level) }
        })
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    /// Built outside the main actor: the audio thread calls this block.
    private nonisolated static func tap(_ report: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            report(min(1, rms * 12))
        }
    }
}
