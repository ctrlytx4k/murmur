@preconcurrency import AVFoundation
import CoreAudio
import os

/// Collects samples on the audio thread. Everything here is off the main actor.
private nonisolated final class CaptureWorker: @unchecked Sendable {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let samples = OSAllocatedUnfairLock(initialState: [Float]())
    private let converter: AVAudioConverter
    private let ratio: Double
    private let report: @Sendable (Float) -> Void

    init?(from format: AVAudioFormat, report: @escaping @Sendable (Float) -> Void) {
        guard let converter = AVAudioConverter(from: format, to: Self.target) else { return nil }
        self.converter = converter
        self.ratio = 16_000 / format.sampleRate
        self.report = report
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        // The converter calls this block synchronously, on this same thread.
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        samples.withLock { $0.append(contentsOf: chunk) }
        report(min(1, (sum / Float(chunk.count)).squareRoot() * 10))
    }

    func take() -> [Float] {
        samples.withLock { all in
            defer { all = [] }
            return all
        }
    }
}

public nonisolated struct NoAudioInput: Error {
    public init() {}
}

/// Microphone capture with AVAudioEngine, converted to 16 kHz mono as it arrives.
public final class LiveAudioCapture: AudioCaptureService {
    /// Called when the input device changes under a take.
    public var onDeviceChange: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var worker: CaptureWorker?
    private var onLevel: ((Float) -> Void)?
    private var configObserver: NSObjectProtocol?

    public init() {}

    public func start(deviceID: String?, onLevel: @escaping (Float) -> Void) throws {
        cancel()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID, var device = Self.coreAudioDevice(forUID: deviceID), let unit = input.audioUnit {
            // Not fatal if it fails: the engine stays on the system default.
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        try install(on: engine)
        self.onLevel = onLevel
        engine.prepare()
        try engine.start()
        self.engine = engine

        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
    }

    public func stop() async throws -> AudioClip {
        let samples = finish()
        return AudioClip(samples: samples)
    }

    public func cancel() {
        _ = finish()
    }

    private func install(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoAudioInput() }
        let existing = worker
        guard let worker = existing ?? CaptureWorker(from: format, report: { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }) else { throw NoAudioInput() }
        self.worker = worker
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tapBlock(worker))
    }

    /// Built outside the main actor: the audio thread calls this block.
    private nonisolated static func tapBlock(_ worker: CaptureWorker) -> AVAudioNodeTapBlock {
        { buffer, _ in worker.process(buffer) }
    }

    /// A microphone was unplugged or the default changed. Keep the take going on whatever is there now.
    private func inputChanged() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        let kept = worker?.take() ?? []
        worker = nil
        do {
            try install(on: engine)
            if !kept.isEmpty { preserved += kept }
            try engine.start()
            onDeviceChange?("Microphone changed. Now using \(AudioDevices.systemDefaultName ?? "the system default").")
        } catch {
            preserved += kept
            onDeviceChange?("The microphone was disconnected.")
        }
    }

    /// Audio captured before a device change, so a mid-take swap does not lose the first half.
    private var preserved: [Float] = []

    private func finish() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let samples = preserved + (worker?.take() ?? [])
        preserved = []
        worker = nil
        onLevel = nil
        return samples
    }

    private static func coreAudioDevice(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}
