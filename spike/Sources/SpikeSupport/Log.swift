import Foundation

/// Nanoseconds on the same clock CGEvent timestamps use (mach absolute time, pauses during sleep).
public func monoNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
public func monoMillis() -> Double { Double(monoNanos()) / 1e6 }

/// Minimal `--key value` / `--flag` parser. Positional args keep their order.
public struct Args {
    public var positional: [String] = []
    public var options: [String: String] = [:]

    public init(_ argv: [String] = Array(CommandLine.arguments.dropFirst())) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]
                    i += 1
                } else {
                    options[key] = "true"
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    public func string(_ key: String, _ fallback: String) -> String { options[key] ?? fallback }
    public func int(_ key: String, _ fallback: Int) -> Int { options[key].flatMap(Int.init) ?? fallback }
    public func double(_ key: String, _ fallback: Double) -> Double { options[key].flatMap(Double.init) ?? fallback }
    public func flag(_ key: String) -> Bool { options[key] != nil }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

/// Chip and OS only. Deliberately no host name, user name or paths.
public func systemInfo() -> [String: Any] {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return [
        "chip": sysctlString("machdep.cpu.brand_string"),
        "model": sysctlString("hw.model"),
        "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
        "build": sysctlString("kern.osversion"),
        "ram_gb": Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)),
        "cores": ProcessInfo.processInfo.processorCount,
    ]
}

/// Append-only JSON-lines log in the results directory. Also echoes to stderr.
public final class ResultLog: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    public let fileName: String

    public init(experiment: String, label: String, args: Args) {
        let fm = FileManager.default
        var dir = args.options["out"] ?? ProcessInfo.processInfo.environment["SPIKE_RESULTS"] ?? ""
        if dir.isEmpty {
            dir = ["results", "spike/results"].first { fm.fileExists(atPath: $0) } ?? "."
        }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        fileName = "\(experiment)-\(label)-\(stamp.string(from: Date())).jsonl"
        let path = (dir as NSString).appendingPathComponent(fileName)
        fm.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path) ?? FileHandle.standardError
        var header = systemInfo()
        header["experiment"] = experiment
        header["label"] = label
        header["launched_as"] = Bundle.main.bundlePath.hasSuffix(".app") ? "app" : "cli"
        write("start", header)
    }

    public func write(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["t_ms"] = NSDecimalNumber(string: String(format: "%.3f", monoMillis()))
        row["wall"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        lock.lock()
        handle.write(data)
        handle.write(Data("\n".utf8))
        lock.unlock()
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

public func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Two decimals, as a decimal number so the JSON does not show binary float noise.
public func round2(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", x)) }
