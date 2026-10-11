import Foundation

/// Stand-ins used only with `--demo`, so the interface can be walked through
/// before the real services exist. They record nothing and type nothing.
final class DemoAudio: AudioCaptureService {
    private var timer: Timer?
    private var tick = 0
    private var onLevel: ((Float) -> Void)?

    func start(deviceID: String?, onLevel: @escaping (Float) -> Void) throws {
        tick = 0
        self.onLevel = onLevel
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                // Bursts of "speech" with short gaps.
                let speaking = (self.tick / 14) % 4 != 3
                self.onLevel?(speaking ? Float.random(in: 0.12...0.95) * Float.random(in: 0.4...1) : Float.random(in: 0...0.04))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() async throws -> AudioClip {
        cancel()
        return AudioClip(samples: [])
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

final class DemoEngine: TranscriptionEngine {
    let displayName = "Demo engine"
    func transcribe(_ clip: AudioClip) async throws -> String {
        try await Task.sleep(for: .milliseconds(900))
        return "Sounds good. I’ll send the revised draft Thursday morning and loop in the design team before the review."
    }
}

final class DemoInsertion: TextInsertionService {
    var isSecureInputActive: Bool { false }
    func insert(_ text: String) async throws -> InsertionReceipt { InsertionReceipt(text: text) }
    func undo(_ receipt: InsertionReceipt) async -> Bool { true }
}

final class DemoPermissions: PermissionsService {
    var current: PermissionSnapshot
    init(_ current: PermissionSnapshot = .allGranted) { self.current = current }
    func snapshot() -> PermissionSnapshot { current }
    func request(_ permission: Permission) {
        switch permission {
        case .microphone: current.microphone = true
        case .accessibility: current.accessibility = true
        case .inputMonitoring: current.inputMonitoring = true
        }
    }
}
