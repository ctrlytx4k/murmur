@preconcurrency import AVFoundation
import AppKit

/// Runs an audio file through both real engines and the cleanup model, without the microphone or any UI.
/// A quick check that the engines work inside the app before a person tries it.
enum SelfTest {
    static func run(clip path: String) {
        Task {
            do {
                let clip = try load(path)
                print("clip: \(String(format: "%.1f", clip.duration)) s")
                let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-selftest")!)
                let router = EngineRouter(settings: settings)

                var heard = ""
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
                        heard = text
                    } catch {
                        print("\(id): FAILED \(error)")
                    }
                }
                let cleanup = AppleCleanup()
                print("cleanup: \(cleanup.availability)")
                if cleanup.availability.isAvailable, !heard.isEmpty {
                    for preset in CleanupPreset.allCases where preset != .custom {
                        let start = Date()
                        do {
                            let text = try await cleanup.clean(heard, instructions: preset.builtInInstructions)
                            print("\(preset.name): \(Int(Date().timeIntervalSince(start) * 1000)) ms\n  \(text)")
                        } catch {
                            print("\(preset.name): FAILED \(error)")
                        }
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

    /// Runs audio files through the meeting pipeline with the real engine: the recorder's file writer, the
    /// track reader, the speech splitter and the transcriber. Everything except the live capture itself.
    static func runMeeting(microphone: String, call: String?) {
        Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-meetingtest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let microphoneURL = folder.appendingPathComponent("microphone.caf"), callURL = folder.appendingPathComponent("call.caf")
                try LiveMeetingAudio.rewrite(URL(fileURLWithPath: microphone), to: microphoneURL)
                if let call { try LiveMeetingAudio.rewrite(URL(fileURLWithPath: call), to: callURL) }
                let size = (try? FileManager.default.attributesOfItem(atPath: microphoneURL.path)[.size] as? Int) ?? 0
                let levels = try await AudioFileTrack(url: microphoneURL).levels()
                print("microphone track: \(size / 1024) KB, \(String(format: "%.1f", Double(levels.count) * SpeechSegmenter.frame)) s, \(SpeechSegmenter.segments(levels: levels).count) stretches of speech")
                let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-selftest")!)
                let router = EngineRouter(settings: settings)
                let start = Date()
                let result = try await MeetingTranscriber.transcribe(
                    microphone: AudioFileTrack(url: microphoneURL), call: call == nil ? nil : AudioFileTrack(url: callURL), engine: router.apple, onProgress: { _ in })
                print("transcribed in \(String(format: "%.1f", Date().timeIntervalSince(start))) s, \(result.lines.count) lines\(result.note.map { ", note: \($0)" } ?? "")")
                for line in result.lines {
                    print("  \(String(format: "%5.1f", line.start)) \(line.speaker?.label ?? "-"): \(line.text)")
                }
                exit(0)
            } catch {
                print("meetingtest failed: \(error)")
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
