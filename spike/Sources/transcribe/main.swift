// Experiment 3: on-device transcription.
//
//   transcribe record --name real-5s --seconds 5 [--ref fixtures/references/5s.txt]
//   transcribe run --engine parakeet|apple --clip audio/x.wav [--ref ref.txt] [--runs 3]
//                  [--realtime]   (apple only: feed audio at speaking pace, time only the tail)
//
// One engine per process so peak memory is not shared between them.

import AVFoundation
import CoreML
import FluidAudio
import Speech
import SpikeSupport

let args = Args()
let mode = args.positional.first ?? "help"

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: audio helpers

let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if buffer.format == format { return buffer }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
        throw SpikeError("no converter from \(buffer.format) to \(format)")
    }
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 4096
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SpikeError("alloc failed") }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if fed {
            status.pointee = .endOfStream
            return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
    }
    if let error { throw error }
    return out
}

func loadClip(_ path: String) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw SpikeError("alloc failed") }
    try file.read(into: buf)
    return try convert(buf, to: format16k)
}

func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func slice(_ buffer: AVAudioPCMBuffer, from: Int, count: Int) -> AVAudioPCMBuffer {
    let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))!
    out.frameLength = AVAudioFrameCount(count)
    let bytes = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
    for ch in 0..<src.count {
        memcpy(dst[ch].mData, src[ch].mData!.advanced(by: from * bytes), count * bytes)
    }
    return out
}

// MARK: process metrics

func footprintMB() -> (current: Double, peak: Double) {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return (0, 0) }
    return (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_lifetime_max_phys_footprint) / 1_048_576)
}

func cpuMillis() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
}

// MARK: accuracy

func words(_ s: String) -> [String] {
    let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
    let cleaned = String(lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " })
    return cleaned.split(separator: " ").map(String.init)
}

/// Word error rate plus the substitutions/insertions/deletions, so the report can show what went wrong.
func wordErrors(reference: String, hypothesis: String) -> (wer: Double, errors: [String]) {
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return (0, []) }
    var d = Array(repeating: Array(repeating: 0, count: h.count + 1), count: r.count + 1)
    for i in 0...r.count { d[i][0] = i }
    for j in 0...h.count { d[0][j] = j }
    for i in 1...r.count {
        for j in stride(from: 1, through: h.count, by: 1) {
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
    }
    var errors: [String] = []
    var i = r.count, j = h.count
    while i > 0 || j > 0 {
        if i > 0, j > 0, r[i - 1] == h[j - 1], d[i][j] == d[i - 1][j - 1] {
            i -= 1; j -= 1
        } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
            errors.append("\(r[i - 1]) -> \(h[j - 1])"); i -= 1; j -= 1
        } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
            errors.append("\(r[i - 1]) -> (dropped)"); i -= 1
        } else {
            errors.append("(added) \(h[j - 1])"); j -= 1
        }
    }
    return (Double(d[r.count][h.count]) / Double(r.count), errors.reversed())
}

// MARK: record

@MainActor func record() async throws {
    let name = args.string("name", "clip")
    let seconds = args.double("seconds", 5)
    let log = ResultLog(experiment: "transcribe", label: "record-\(name)", args: args)

    var status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        status = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    log.write("mic_permission", ["status": status.rawValue, "authorized": status == .authorized])
    guard status == .authorized else { throw SpikeError("microphone not authorized for the launching app") }

    if let ref = args.options["ref"], let text = try? String(contentsOfFile: ref, encoding: .utf8) {
        FileHandle.standardError.write(Data("\nRead this aloud at a normal pace when recording starts:\n\n\(text)\n\n".utf8))
    }
    for s in stride(from: 3, to: 0, by: -1) {
        FileHandle.standardError.write(Data("Recording \(Int(seconds))s in \(s)...\n".utf8))
        try await Task.sleep(for: .seconds(1))
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    let lock = NSLock()
    var chunks: [AVAudioPCMBuffer] = []
    var firstBufferAt: Double?

    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        lock.lock()
        if firstBufferAt == nil { firstBufferAt = monoMillis() }
        chunks.append(buffer)
        lock.unlock()
    }
    // "Key down" is here: how long until audio actually flows decides whether the first word gets clipped.
    let t0 = monoMillis()
    engine.prepare()
    try engine.start()
    let started = monoMillis()
    FileHandle.standardError.write(Data("● recording\n".utf8))
    try await Task.sleep(for: .seconds(seconds))
    engine.stop()
    input.removeTap(onBus: 0)
    FileHandle.standardError.write(Data("■ stopped\n".utf8))

    let total = chunks.reduce(0) { $0 + Int($1.frameLength) }
    guard total > 0, let joined = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(total)) else {
        throw SpikeError("no audio captured")
    }
    for chunk in chunks {
        let dst = UnsafeMutableAudioBufferListPointer(joined.mutableAudioBufferList)
        let src = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
        let bytes = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        for ch in 0..<src.count {
            memcpy(dst[ch].mData!.advanced(by: Int(joined.frameLength) * bytes), src[ch].mData, Int(chunk.frameLength) * bytes)
        }
        joined.frameLength += chunk.frameLength
    }
    let mono = try convert(joined, to: format16k)
    let data = samples(mono)
    let rms = (data.reduce(0) { $0 + $1 * $1 } / Float(max(data.count, 1))).squareRoot()

    try FileManager.default.createDirectory(atPath: "audio", withIntermediateDirectories: true)
    let file = try AVAudioFile(
        forWriting: URL(fileURLWithPath: "audio/\(name).wav"), settings: format16k.settings,
        commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: mono)

    log.write("recorded", [
        "clip": name,
        "input_sample_rate": inputFormat.sampleRate,
        "input_channels": inputFormat.channelCount,
        "engine_start_ms": round2(started - t0),
        "first_buffer_after_ms": round2((firstBufferAt ?? started) - t0),
        "rms_is_x1000": true,
        "captured_seconds": round2(Double(data.count) / 16_000),
        "requested_seconds": seconds,
        "rms": round2(Double(rms) * 1000),
        "looks_silent": rms < 0.001,
    ])
}

// MARK: engines

struct RunResult {
    var text: String
    var latencyMs: Double
    var extra: [String: Any] = [:]
}

func runParakeet(_ clip: AVAudioPCMBuffer, runs: Int, log: ResultLog) async throws -> [RunResult] {
    let pcm = samples(clip)
    let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models")
    let cached = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).contains { $0.contains("parakeet") }
    let t0 = monoMillis()
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    let mem = footprintMB()
    log.write("model_loaded", [
        "engine": "parakeet-v3",
        "load_ms": round2(monoMillis() - t0),
        "includes_download": !cached,
        "footprint_mb": round2(mem.current),
    ])
    var out: [RunResult] = []
    for _ in 0..<runs {
        var state = TdtDecoderState.make()
        let t = monoMillis()
        let result = try await asr.transcribe(pcm, decoderState: &state)
        out.append(RunResult(text: result.text, latencyMs: monoMillis() - t, extra: ["confidence": round2(Double(result.confidence))]))
    }
    return out
}

@available(macOS 26.0, *)
@MainActor func runApple(_ clip: AVAudioPCMBuffer, runs: Int, realtime: Bool, log: ResultLog) async throws -> [RunResult] {
    let locale = Locale(identifier: args.string("locale", "en-US"))
    var out: [RunResult] = []
    for run in 0..<runs {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if run == 0 {
            let status = await AssetInventory.status(forModules: [transcriber])
            log.write("apple_assets", [
                "status": String(describing: status),
                "locale_supported": await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) },
                "installed_locales": await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) },
                "speech_recognition_auth": SFSpeechRecognizer.authorizationStatus().rawValue,
            ])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let t = monoMillis()
                try await request.downloadAndInstall()
                log.write("apple_assets_installed", ["download_ms": round2(monoMillis() - t)])
            }
        }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpikeError("SpeechAnalyzer offered no audio format")
        }
        let t0 = monoMillis()
        try await analyzer.prepareToAnalyze(in: format)
        if run == 0 {
            log.write("model_loaded", [
                "engine": "apple-speechanalyzer",
                "load_ms": round2(monoMillis() - t0),
                "analyzer_format": "\(format.sampleRate) Hz, \(format.channelCount) ch, \(format.commonFormat.rawValue)",
                "footprint_mb": round2(footprintMB().current),
            ])
        }
        let audio = try convert(clip, to: format)
        let collector = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        var released = monoMillis()
        if realtime {
            // Feed 100 ms chunks at speaking pace, as a live recording would. Only the
            // time after the last chunk counts: that is what the user waits for.
            let step = Int(format.sampleRate / 10)
            let begin = monoMillis()
            var offset = 0, n = 0
            while offset < Int(audio.frameLength) {
                let count = min(step, Int(audio.frameLength) - offset)
                feed.yield(AnalyzerInput(buffer: slice(audio, from: offset, count: count)))
                offset += count
                n += 1
                let due = begin + Double(n) * 100
                let wait = due - monoMillis()
                if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait))) }
            }
            released = monoMillis()
        } else {
            feed.yield(AnalyzerInput(buffer: audio))
        }
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value
        out.append(RunResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), latencyMs: monoMillis() - released))
    }
    return out
}

@MainActor func run() async throws {
    let engine = args.string("engine", "parakeet")
    guard let clipPath = args.options["clip"] else { throw SpikeError("--clip is required") }
    let clipName = URL(fileURLWithPath: clipPath).deletingPathExtension().lastPathComponent
    let realtime = args.flag("realtime")
    let log = ResultLog(experiment: "transcribe", label: "\(engine)\(realtime ? "-realtime" : "")-\(clipName)", args: args)
    let reference = args.options["ref"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    let runs = args.int("runs", 3)

    let clip = try loadClip(clipPath)
    let audioSeconds = Double(clip.frameLength) / 16_000
    let cpu0 = cpuMillis(), wall0 = monoMillis()

    let results: [RunResult]
    do {
        switch engine {
        case "parakeet":
            results = try await runParakeet(clip, runs: runs, log: log)
        case "apple":
            guard #available(macOS 26.0, *) else { throw SpikeError("SpeechAnalyzer needs macOS 26") }
            results = try await runApple(clip, runs: runs, realtime: realtime, log: log)
        default:
            throw SpikeError("unknown engine \(engine)")
        }
    } catch {
        log.write("engine_failed", ["engine": engine, "clip": clipName, "error": String(describing: error)])
        throw error
    }

    for (i, r) in results.enumerated() {
        var row: [String: Any] = r.extra
        row["engine"] = engine
        row["clip"] = clipName
        row["mode"] = realtime ? "realtime-feed" : "batch-after-release"
        row["run"] = i + 1
        row["audio_seconds"] = round2(audioSeconds)
        row["latency_ms"] = round2(r.latencyMs)
        row["speed_x_realtime"] = round2(audioSeconds * 1000 / max(r.latencyMs, 0.001))
        row["text"] = r.text
        if let reference {
            let (wer, errors) = wordErrors(reference: reference, hypothesis: r.text)
            row["wer_pct"] = round2(wer * 100)
            row["word_errors"] = errors
            row["reference_words"] = words(reference).count
        }
        log.write("run", row)
    }
    let mem = footprintMB()
    let lat = results.map(\.latencyMs)
    log.write("summary", [
        "engine": engine,
        "clip": clipName,
        "mode": realtime ? "realtime-feed" : "batch-after-release",
        "audio_seconds": round2(audioSeconds),
        "latency_first_ms": round2(lat.first ?? 0),
        "latency_warm_median_ms": round2(median(Array(lat.dropFirst())).isZero ? (lat.first ?? 0) : median(Array(lat.dropFirst()))),
        "peak_footprint_mb": round2(mem.peak),
        "end_footprint_mb": round2(mem.current),
        "process_cpu_ms": round2(cpuMillis() - cpu0),
        "process_wall_ms": round2(monoMillis() - wall0),
        "note": "footprint and CPU are for this process only; work done in system daemons or on the ANE is not counted",
    ])
}

do {
    switch mode {
    case "record": try await record()
    case "run": try await run()
    default:
        print("usage: transcribe record --name <clip> --seconds <n> [--ref file]")
        print("       transcribe run --engine parakeet|apple --clip <file> [--ref file] [--runs 3] [--realtime]")
    }
} catch {
    FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
    exit(1)
}
