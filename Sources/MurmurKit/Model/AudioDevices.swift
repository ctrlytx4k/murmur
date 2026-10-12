import AVFoundation
import CoreAudio
import Observation

public nonisolated struct InputDevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// How it is connected, in a word: "Built-in", "USB", "Bluetooth". Nil when Core Audio does not say.
    public var connection: String?
}

/// Input devices, read straight from Core Audio so the list matches System Settings > Sound.
enum AudioDevices {
    static func inputs() -> [InputDevice] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            // AVAudioEngine makes private aggregate devices for its own use. They are not microphones.
            if transport(id) == kAudioDeviceTransportTypeAggregate, name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return InputDevice(id: uid, name: name, connection: connectionName(transport(id)))
        }
    }

    private static func connectionName(_ transport: UInt32) -> String? {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "Display"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "iPhone"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: "Virtual"
        default: nil
        }
    }

    struct MenuOptions {
        var options: [(value: String?, label: String)]
        var details: [String?: String]
        /// The saved microphone, when it is not plugged in. Murmur records from the system default meanwhile.
        var disconnected: Set<String?>
    }

    /// The microphone choices as menu rows, shared by Settings and the menu bar dropdown.
    static func menuOptions(saved: String?, savedName: String?) -> MenuOptions {
        let devices = inputs()
        var options: [(value: String?, label: String)] = [(nil, "System Default")] + devices.map { (Optional($0.id), $0.name) }
        var details: [String?: String] = [nil: systemDefaultName.map { "Follows System Settings · \($0)" } ?? "Follows System Settings"]
        for device in devices { details[device.id] = device.connection }
        var disconnected: Set<String?> = []
        if let saved, !devices.contains(where: { $0.id == saved }) {
            options.append((saved, savedName ?? "Saved microphone"))
            details[saved] = "Not connected · using default"
            disconnected.insert(saved)
        }
        return MenuOptions(options: options, details: details, disconnected: disconnected)
    }

    static var systemDefaultName: String? {
        var id = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id), id != 0 else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    /// The name to show for a stored choice; falls back to the system default when the device is gone.
    static func displayName(for id: String?) -> String {
        if let id, let match = inputs().first(where: { $0.id == id }) { return match.name }
        return systemDefaultName ?? "No microphone"
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        return read(id, kAudioDevicePropertyTransportType, &value) ? value : 0
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) } == noErr
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard read(id, selector, &value), let value else { return nil }
        return value.takeRetainedValue() as String
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
