// Whisper (via WhisperKit) on the same clips as the Parakeet and SpeechAnalyzer runs.
//
//   whisperbench <model> <clip> <reference.txt> [runs]
//
// Writes one JSON-lines file to ../results, with the same fields as the other engines.

import AVFoundation
import Foundation
import WhisperKit

let argv = CommandLine.arguments
guard argv.count >= 4 else {
    print("usage: whisperbench <model> <clip> <reference.txt> [runs]")
    exit(1)
}
let model = argv[1], clipPath = argv[2], refPath = argv[3]
let runs = argv.count > 4 ? Int(argv[4]) ?? 3 : 3
let clipName = URL(fileURLWithPath: clipPath).deletingPathExtension().lastPathComponent

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
func r2(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", x)) }

func sysctl(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

let stamp = DateFormatter()
stamp.dateFormat = "yyyyMMdd-HHmmss"
let outPath = "../results/transcribe-whisper-\(model.replacingOccurrences(of: "_", with: "-"))-\(clipName)-\(stamp.string(from: Date())).jsonl"
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)!
func log(_ event: String, _ fields: [String: Any]) {
    var row = fields
    row["event"] = event
    row["wall"] = ISO8601DateFormatter().string(from: Date())
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    out.write(data); out.write(Data("\n".utf8))
    FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
}

func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: source)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: source.format, to: target)!
    let capacity = AVAudioFrameCount(Double(source.frameLength) * 16_000 / source.format.sampleRate) + 4096
    let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
    var fed = false
    var error: NSError?
    converter.convert(to: converted, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return source
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
}

func words(_ s: String) -> [String] {
    let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
    return String(lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " })
        .split(separator: " ").map(String.init)
}

func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return 0 }
    var previous = Array(0...h.count)
    for i in 1...r.count {
        var current = [i] + Array(repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return Double(previous[h.count]) / Double(r.count)
}

func peakFootprintMB() -> Double {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : 0
}

do {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    log("start", ["experiment": "transcribe", "engine": "whisper", "model": model, "chip": sysctl("machdep.cpu.brand_string"),
                  "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"])
    let samples = try loadSamples(clipPath)
    let reference = try String(contentsOfFile: refPath, encoding: .utf8)
    let seconds = Double(samples.count) / 16_000

    let t0 = now()
    let whisper = try await WhisperKit(WhisperKitConfig(model: model, verbose: false, logLevel: .error))
    log("model_loaded", ["engine": "whisper", "model": model, "load_ms": r2(now() - t0), "note": "includes download and Core ML compile on the first run"])

    var latencies: [Double] = []
    for run in 1...runs {
        let t = now()
        let results = try await whisper.transcribe(audioArray: samples)
        let latency = now() - t
        latencies.append(latency)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        log("run", ["engine": "whisper", "model": model, "clip": clipName, "mode": "batch-after-release", "run": run,
                    "audio_seconds": r2(seconds), "latency_ms": r2(latency), "speed_x_realtime": r2(seconds * 1000 / latency),
                    "wer_pct": r2(wordErrorRate(reference: reference, hypothesis: text) * 100), "text": text])
    }
    let warm = latencies.dropFirst().sorted()
    log("summary", ["engine": "whisper", "model": model, "clip": clipName, "audio_seconds": r2(seconds),
                    "latency_first_ms": r2(latencies[0]), "latency_warm_median_ms": r2(warm.isEmpty ? latencies[0] : warm[warm.count / 2]),
                    "peak_footprint_mb": r2(peakFootprintMB())])
} catch {
    log("engine_failed", ["engine": "whisper", "model": model, "clip": clipName, "error": String(describing: error)])
    exit(1)
}
