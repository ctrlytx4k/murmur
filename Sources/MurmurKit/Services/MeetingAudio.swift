@preconcurrency import AVFoundation
import CoreAudio
import os

/// Writes one track to disk as 16 kHz mono, whatever format it arrives in. Called from audio threads.
private nonisolated final class TrackWriter: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private var frames = 0
    private var peak: Float = 0
    private var buffers = 0
    private var unreadable = 0
    private var sourceFormat = ""
    private let started = ProcessInfo.processInfo.systemUptime
    private let report: (@Sendable (Float) -> Void)?

    init(url: URL, report: (@Sendable (Float) -> Void)? = nil) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.report = report
    }

    /// The capture handed over something that could not be turned into a buffer.
    func noteUnreadable() {
        lock.lock()
        unreadable += 1
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let mono = Self.mono(buffer) else { return noteUnreadable() }
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        if sourceFormat.isEmpty {
            sourceFormat = "\(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch\(buffer.format.isInterleaved ? ", interleaved" : "")"
        }
        guard let file, let out = resample(mono), out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        // Both tracks follow the clock, so they stay lined up: a gap (a device switch, a late start) is written as silence.
        let expected = Int((ProcessInfo.processInfo.systemUptime - started) * Self.sampleRate)
        let missing = expected - frames - Int(out.frameLength)
        if missing > Int(Self.sampleRate / 4), let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(missing)) {
            silence.frameLength = AVAudioFrameCount(missing)
            if (try? file.write(from: silence)) != nil { frames += missing }
        }
        var sum: Float = 0
        for index in 0..<Int(out.frameLength) {
            let sample = data[index]
            sum += sample * sample
            peak = max(peak, abs(sample))
        }
        guard (try? file.write(from: out)) != nil else { return }
        frames += Int(out.frameLength)
        report?(min(1, (sum / Float(out.frameLength)).squareRoot() * 10))
    }

    /// Closes the file. Returns how long the track is, the loudest sample in it, and a line for the debug log.
    func close() -> (duration: Double, peak: Float, summary: String) {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
        let summary = "\(buffers) buffers (\(sourceFormat.isEmpty ? "none arrived" : sourceFormat)), \(unreadable) unreadable, \(String(format: "%.1f", Double(frames) / Self.sampleRate)) s written, peak \(String(format: "%.4f", peak))"
        return (Double(frames) / Self.sampleRate, peak, summary)
    }

    private func resample(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let rate = mono.format.sampleRate
        if rate == Self.sampleRate { return mono }
        if converter == nil || converterRate != rate {
            converter = AVAudioConverter(from: mono.format, to: Self.format)
            converterRate = rate
        }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Double(mono.frameLength) * Self.sampleRate / rate) + 64) else { return nil }
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
            return mono
        }
        return error == nil ? out : nil
    }

    /// Averages the channels of a float buffer into one.
    private static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let channels = Int(format.channelCount), frames = Int(buffer.frameLength)
        guard format.commonFormat == .pcmFormatFloat32, channels > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength), let target = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let scale = 1 / Float(channels)
        if format.isInterleaved {
            guard let source = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[frame * channels + channel] }
                target[frame] = sum * scale
            }
        } else {
            for frame in 0..<frames { target[frame] = 0 }
            for channel in 0..<min(channels, list.count) {
                guard let source = list[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames { target[frame] += source[frame] * scale }
            }
        }
        return out
    }
}

public nonisolated struct SystemAudioFailure: LocalizedError {
    let step: String
    let status: OSStatus
    public var errorDescription: String? { "Couldn’t capture the call’s audio (\(step), error \(status))." }
}

/// Everything the Mac plays, through a Core Audio process tap. Audio only: this never touches the screen.
/// macOS asks for "System Audio Recording" the first time it runs.
private final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private let tapUUID = UUID()
    private let queue = DispatchQueue(label: "app.murmur.meeting-tap", qos: .userInitiated)
    private var outputListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// `writer` is nil when the only point is to make macOS ask for permission.
    func start(writer: TrackWriter?) throws {
        stop()
        self.writer = writer
        // Murmur's own sounds stay out of the recording.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = tapUUID
        description.name = "Murmur meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw SystemAudioFailure(step: "creating the tap", status: status) }
        tapID = tap
        do {
            try attach()
        } catch {
            stop()
            throw error
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.outputChanged() }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
    }

    func stop() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, outputListener)
        }
        outputListener = nil
        detach()
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        writer = nil
    }

    /// The tap is read through a private aggregate device clocked by the current output.
    private func attach() throws {
        guard let output = Self.defaultOutputUID() else { throw SystemAudioFailure(step: "finding the output device", status: -1) }
        var streamFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamFormat)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamFormat) else { throw SystemAudioFailure(step: "reading the tap format", status: status) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw SystemAudioFailure(step: "creating the capture device", status: status) }
        aggregateID = aggregate
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, Self.ioBlock(writer: writer, format: format))
        guard status == noErr, let proc else { throw SystemAudioFailure(step: "reading the capture device", status: status) }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw SystemAudioFailure(step: "starting the capture device", status: status) }
        DebugLog.log("meeting: call capture started, tap format \(Int(format.sampleRate)) Hz, \(format.channelCount) ch\(format.isInterleaved ? ", interleaved" : "")")
    }

    private func detach() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Headphones plugged in or pulled out mid-call: rebuild the capture device around the new output.
    private func outputChanged() {
        guard tapID != kAudioObjectUnknown else { return }
        detach()
        do {
            try attach()
            DebugLog.log("meeting: output device changed, call capture restarted")
        } catch {
            DebugLog.log("meeting: call capture lost after an output change, \(error)")
        }
    }

    /// Built outside the main actor: Core Audio calls this block on its own queue.
    private nonisolated static func ioBlock(writer: TrackWriter?, format: AVAudioFormat) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            guard let writer else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return writer.noteUnreadable() }
            writer.write(buffer)
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Records a meeting: the microphone with AVAudioEngine, the call with a system audio tap, each to its own file.
public final class LiveMeetingAudio: MeetingAudioService {
    private var engine: AVAudioEngine?
    private var microphone: TrackWriter?
    private var call: TrackWriter?
    private let tap = SystemAudioTap()
    private var probe: SystemAudioTap?
    private var configObserver: NSObjectProtocol?
    private var restartPending = false
    private var onLevel: ((Float) -> Void)?

    public init() {}

    public func start(microphone url: URL, call callURL: URL?, microphoneID: String?, onLevel: @escaping (Float) -> Void) throws {
        _ = stop()
        self.onLevel = onLevel
        let writer = try TrackWriter(url: url) { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        microphone = writer
        let engine = AVAudioEngine()
        if let microphoneID, var device = LiveAudioCapture.coreAudioDevice(forUID: microphoneID), let unit = engine.inputNode.audioUnit {
            // Not fatal if it fails: the engine stays on the system default.
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        do {
            try install(on: engine, writer: writer)
            engine.prepare()
            try engine.start()
        } catch {
            _ = writer.close()
            microphone = nil
            throw error
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
        if let callURL {
            // The meeting still records without the call: the transcript then says the call was not heard.
            do {
                let callWriter = try TrackWriter(url: callURL)
                try tap.start(writer: callWriter)
                call = callWriter
            } catch {
                DebugLog.log("meeting: call audio unavailable, \(error)")
                try? FileManager.default.removeItem(at: callURL)
            }
        }
    }

    public func stop() -> MeetingRecording {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tap.stop()
        onLevel = nil
        let microphoneEnd = microphone?.close()
        let callEnd = call?.close()
        if let microphoneEnd { DebugLog.log("meeting: microphone track, \(microphoneEnd.summary)") }
        if let callEnd { DebugLog.log("meeting: call track, \(callEnd.summary)") }
        microphone = nil
        call = nil
        return MeetingRecording(duration: max(microphoneEnd?.duration ?? 0, callEnd?.duration ?? 0), callWasSilent: callEnd.map { $0.peak == 0 } ?? false)
    }

    public func requestSystemAudio() {
        let probe = SystemAudioTap()
        self.probe = probe
        do {
            try probe.start(writer: nil)
        } catch {
            DebugLog.log("meeting: could not ask for system audio, \(error)")
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            probe.stop()
            if self.probe === probe { self.probe = nil }
        }
    }

    /// Runs an audio file through the same writer a live recording uses. For `--meetingtest` only.
    nonisolated static func rewrite(_ source: URL, to target: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let writer = try TrackWriter(url: target)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 4096)
            if buffer.frameLength == 0 { break }
            writer.write(buffer)
        }
        _ = writer.close()
    }

    private func install(on engine: AVAudioEngine, writer: TrackWriter) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoAudioInput() }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(writer))
    }

    /// Built outside the main actor: the audio thread calls this block.
    private nonisolated static func tapBlock(_ writer: TrackWriter) -> AVAudioNodeTapBlock {
        { buffer, _ in writer.write(buffer) }
    }

    /// The microphone changed mid-meeting (AirPods connected, a headset unplugged): carry on with the new one.
    private func inputChanged() {
        guard engine != nil, !restartPending else { return }
        restartPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            self.restartPending = false
            guard let engine = self.engine, let writer = self.microphone else { return }
            engine.inputNode.removeTap(onBus: 0)
            do {
                try self.install(on: engine, writer: writer)
                if !engine.isRunning { try engine.start() }
                DebugLog.log("meeting: microphone changed, recording continues")
            } catch {
                DebugLog.log("meeting: microphone lost, \(error)")
            }
        }
    }
}

/// A recorded track on disk, read a piece at a time.
public nonisolated struct AudioFileTrack: MeetingTrack {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func levels() async throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let frame = Int(rate * SpeechSegmenter.frame)
        // Ten seconds at a time, so an hour-long call never sits in memory whole.
        let capacity = AVAudioFrameCount(frame * 500)
        guard frame > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(Int(file.length) / frame + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            var index = 0
            while index < Int(buffer.frameLength) {
                let end = min(index + frame, Int(buffer.frameLength))
                var sum: Float = 0
                for sample in index..<end { sum += data[sample] * data[sample] }
                levels.append((sum / Float(end - index)).squareRoot())
                index = end
            }
        }
        return levels
    }

    public func clip(from start: Double, to end: Double) async throws -> AudioClip {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let first = min(max(AVAudioFramePosition(start * rate), 0), file.length)
        let count = AVAudioFrameCount(max(0, min(AVAudioFramePosition(end * rate), file.length) - first))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return AudioClip(samples: [], sampleRate: rate) }
        file.framePosition = first
        try file.read(into: buffer, frameCount: count)
        guard let data = buffer.floatChannelData?[0] else { return AudioClip(samples: [], sampleRate: rate) }
        return AudioClip(samples: Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))), sampleRate: rate)
    }
}
