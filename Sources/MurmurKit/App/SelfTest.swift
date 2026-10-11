@preconcurrency import AVFoundation
import AppKit

/// Runs an audio file through both real engines, without the microphone or any UI.
/// A quick check that the engines work inside the app before a person tries it.
enum SelfTest {
    static func run(clip path: String) {
        Task {
            do {
                let clip = try load(path)
                print("clip: \(String(format: "%.1f", clip.duration)) s")
                let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-selftest")!)
                let router = EngineRouter(settings: settings)

                for (id, engine) in [("apple-speech", router.apple as any TranscriptionEngine), ("parakeet-v3", router.parakeet)] {
                    let start = Date()
                    do {
                        if id == "parakeet-v3" {
                            guard router.parakeet.isInstalled else {
                                print("\(id): not downloaded, skipped")
                                continue
                            }
                            try await router.parakeet.prepare()
                        }
                        let loaded = Date()
                        let text = try await engine.transcribe(clip)
                        print("\(id): load \(Int(loaded.timeIntervalSince(start) * 1000)) ms, transcribe \(Int(Date().timeIntervalSince(loaded) * 1000)) ms")
                        print("  \(text)")
                    } catch {
                        print("\(id): FAILED \(error)")
                    }
                }
                exit(0)
            } catch {
                print("selftest failed: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    private static func load(_ path: String) throws -> AudioClip {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw EngineNotReady() }
        try file.read(into: source)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * 16_000 / source.format.sampleRate) + 4096)
        else { throw EngineNotReady() }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return AudioClip(samples: Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
    }
}
