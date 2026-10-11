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
        return "um so sounds good uh i’ll send the revised draft thursday morning and like loop in the design team before the review"
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

/// Drops filler words and tidies casing, so Cleaned up mode has something to show in the demo.
final class DemoCleanup: TextCleanupService {
    func clean(_ text: String, instructions: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        let fillers: Set<String> = ["um", "uh", "so", "like"]
        var words = text.split(separator: " ").map(String.init).filter { !fillers.contains($0.lowercased()) }
        words = words.map { ["i’ll": "I’ll", "thursday": "Thursday"][$0] ?? $0 }
        guard !words.isEmpty else { return text }
        words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
        var sentence = words.joined(separator: " ")
        sentence = sentence.replacingOccurrences(of: "good I’ll", with: "good. I’ll")
        return sentence + "."
    }
}

/// The sample content from the mockups, used only with `--demo` and for snapshots.
enum DemoData {
    static func seed(_ stores: Stores) {
        if stores.dictionary.entries.isEmpty {
            stores.dictionary.entries = [
                ("kube cuttle", "kubectl", "All apps"), ("post gres", "Postgres", "All apps"), ("jason", "JSON", "Xcode, Terminal"),
                ("sequel light", "SQLite", "All apps"), ("ts config", "tsconfig", "Code editors"), ("eye oh ess", "iOS", "All apps"),
            ].map { DictionaryEntry(spoken: $0.0, written: $0.1, scope: $0.2) }
        }
        if stores.dictionary.snippets.isEmpty {
            stores.dictionary.snippets = [
                Snippet(trigger: "my address", text: "[YOUR STREET ADDRESS]\n[CITY, STATE ZIP]"),
                Snippet(trigger: "standup template", text: "Yesterday:\nToday:\nBlockers:"),
                Snippet(trigger: "today’s date", text: "{date}"),
                Snippet(trigger: "scheduling link", text: "[YOUR SCHEDULING LINK]"),
            ]
        }
        if stores.history.entries.isEmpty {
            let now = Date()
            func entry(_ minutesAgo: Double, _ app: String, _ id: String, _ mode: DictationMode, _ text: String, raw: String? = nil, seconds: Double = 9) -> HistoryEntry {
                HistoryEntry(date: now.addingTimeInterval(-minutesAgo * 60), appName: app, bundleIdentifier: id, mode: mode, text: text, raw: raw, audioSeconds: seconds, engine: "parakeet-v3")
            }
            stores.history.replaceAll([
                entry(2, "Slack", "com.tinyspeck.slackmacgap", .cleaned, "Sounds good. I’ll send the revised draft Thursday morning and loop in the design team before the review.",
                      raw: "um so sounds good uh i’ll send the revised draft thursday morning and like loop in the design team before the review", seconds: 14),
                entry(29, "Notes", "com.apple.Notes", .raw, "decision we’ll ship the beta to testers on friday and collect feedback through the form"),
                entry(253, "Mail", "com.apple.mail", .cleaned, "Thanks for the quick turnaround. The new layout works; one small note on the pricing table below.",
                      raw: "thanks for the quick turnaround um the new layout works one small note on the pricing table below"),
                entry(280, "Notes", "com.apple.Notes", .command, "“Turn the last three lines into a bulleted list”", seconds: 4),
                entry(1250, "Messages", "com.apple.MobileSMS", .cleaned, "On my way, there in ten.", raw: "on my way there in ten", seconds: 3),
                entry(1385, "Xcode", "com.apple.dt.Xcode", .raw, "add a guard for the empty array case before the loop", seconds: 5),
            ])
        }
        if stores.network.entries.isEmpty {
            stores.network.record(host: "github.com", reason: "Update check (signed feed)", bytes: 4_096, date: Date().addingTimeInterval(-3 * 86_400))
            stores.network.record(host: "huggingface.co", reason: "Model download · parakeet-v3", bytes: 480_000_000, date: Date().addingTimeInterval(-3_000))
            stores.network.record(host: "github.com", reason: "Update check (signed feed)", bytes: 4_096, date: Date().addingTimeInterval(-900))
        }
        if stores.settings.appPresets.isEmpty {
            stores.settings.appPresets = [
                AppPreset(bundleIdentifier: "com.apple.mail", name: "Mail", preset: CleanupPreset.polished.rawValue),
                AppPreset(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack", preset: CleanupPreset.lightTouch.rawValue),
                AppPreset(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", preset: "raw"),
                AppPreset(bundleIdentifier: "com.apple.Terminal", name: "Terminal", preset: "raw"),
            ]
        }
    }
}
