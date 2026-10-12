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
        }
    }
}

/// A meeting recorder that records nothing: the level moves, and Stop hands back a short "recording".
final class DemoMeetingAudio: MeetingAudioService {
    private var timer: Timer?
    private var started = Date()
    private var onLevel: ((Float) -> Void)?

    func start(microphone: URL, call: URL?, microphoneID: String?, onLevel: @escaping (Float) -> Void) throws {
        started = Date()
        self.onLevel = onLevel
        // Empty files stand in for the tracks, so the rest of the flow finds what it expects.
        FileManager.default.createFile(atPath: microphone.path, contents: nil)
        if let call { FileManager.default.createFile(atPath: call.path, contents: nil) }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLevel?(Float.random(in: 0.1...0.8)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() -> MeetingRecording {
        timer?.invalidate()
        timer = nil
        return MeetingRecording(duration: Date().timeIntervalSince(started))
    }

    func requestSystemAudio() {}
}

/// A track with two bursts of "speech", so the demo transcript has a few lines.
nonisolated struct DemoMeetingTrack: MeetingTrack {
    var offset = 0.0
    func levels() async throws -> [Float] {
        let quiet = [Float](repeating: 0, count: Int(1 / SpeechSegmenter.frame)), speech = [Float](repeating: 0.1, count: Int(2 / SpeechSegmenter.frame))
        return [Float](repeating: 0, count: Int(offset / SpeechSegmenter.frame)) + speech + quiet + quiet + quiet + speech + quiet
    }
    func clip(from start: Double, to end: Double) async throws -> AudioClip { AudioClip(samples: []) }
}

/// Drops filler words and tidies casing, so Cleaned up mode has something to show in the demo.
final class DemoCleanup: TextCleanupService, LocalTextModel {
    func generate(system: String, user: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        return DemoData.summaryText
    }

    let availability = CleanupAvailability.available(model: "demo-cleanup")
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
    static let summaryText = """
    Key points
    - The language step in onboarding works well.
    - The engine step feels heavy for first-time users.
    - The engine will be picked automatically, with the choice kept in Settings.

    Action items
    - Priya: update the onboarding flow, by Thursday
    """

    /// The meetings on the Meetings board.
    static func meetings(now: Date = Date()) -> [Meeting] {
        let calendar = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        var review = Meeting(title: "Design review", date: at(0, 9, 30), duration: 32 * 60, includesCallAudio: true)
        review.setTranscript([
            MeetingLine(start: 60, speaker: .you, text: "Okay so um let’s start with the onboarding flow. Did everyone get a chance to look at the uh new mockups?"),
            MeetingLine(start: 85, speaker: .others, voice: 1, text: "Yes. The language step is good, but the engine step feels heavy for first-time users."),
            MeetingLine(start: 180, speaker: .others, voice: 2, text: "We could pick the engine automatically and only show the choice in settings."),
            MeetingLine(start: 840, speaker: .you, text: "Let’s do that. Priya, can you update the flow by Thursday?"),
        ], engine: "parakeet-v3")
        review.hasAudio = false
        review.speakerNames = ["1": "Priya"]
        var oneOnOne = Meeting(title: "1:1 with Sam", date: at(0, 8, 45), duration: 18 * 60, includesCallAudio: true)
        oneOnOne.setTranscript([MeetingLine(start: 5, speaker: .you, text: "Morning. How did the release go?")], engine: "parakeet-v3")
        oneOnOne.hasAudio = false
        var sync = Meeting(title: "Beta launch sync", date: at(1, 15, 0), duration: 41 * 60, includesCallAudio: true)
        sync.setTranscript([MeetingLine(start: 12, speaker: .others, text: "Let’s go through the launch checklist.")], engine: "parakeet-v3")
        sync.hasAudio = false
        return [review, oneOnOne, sync]
    }

    static func seed(_ stores: Stores) {
        if stores.meetings.meetings.isEmpty { meetings().forEach(stores.meetings.add) }
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
        if stores.stats.rows.isEmpty { stores.stats.replaceAll(StatsFixture.rows(today: Stats.today())) }
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

/// Sample stats that reproduce the numbers on the mockup's Stats board: 8,412 words in the last 7 days
/// against 7,511 before, 63 takes, 58 minutes of talking. Used with `--demo`, for snapshots and in tests.
enum StatsFixture {
    /// The day the mockup was drawn on: a Monday, with Wed Oct 7 as its tallest bar.
    static let mockupToday = LocalDay("2026-10-12")

    private static let apps: [String: String] = [
        "Slack": "com.tinyspeck.slackmacgap", "Mail": "com.apple.mail", "Notes": "com.apple.Notes", "Xcode": "com.apple.dt.Xcode",
        "Messages": "com.apple.MobileSMS", "Safari": "com.apple.Safari", "Terminal": "com.apple.Terminal",
    ]

    static func rows(today: LocalDay = mockupToday) -> [TakeStat] {
        var rows: [TakeStat] = []
        // The last 7 days, oldest first: takes, seconds of talking, and words by app.
        let week: [(takes: Int, seconds: Int, words: [(String, Int)])] = [
            (12, 660, [("Slack", 700), ("Mail", 400), ("Notes", 250), ("Xcode", 229)]),
            (14, 780, [("Slack", 810), ("Mail", 458), ("Notes", 300), ("Xcode", 238), ("Messages", 100)]),
            (10, 549, [("Slack", 560), ("Mail", 330), ("Notes", 200), ("Xcode", 236)]),
            (13, 780, [("Slack", 780), ("Mail", 420), ("Notes", 287), ("Xcode", 237), ("Terminal", 160)]),
            (3, 109, [("Notes", 153), ("Messages", 110)]),
            (8, 473, [("Notes", 420), ("Mail", 300), ("Safari", 232), ("Messages", 100), ("Slack", 90)]),
            (3, 129, [("Slack", 180), ("Mail", 132)]),
        ]
        for (index, day) in week.enumerated() {
            rows += spread(day.words, takes: day.takes, seconds: day.seconds, on: today.adding(index - 6))
        }
        // The 7 days before, and a lighter month before that.
        let before: [(Int, Int)] = [(1421, 10), (1305, 9), (1663, 12), (1200, 9), (0, 0), (537, 4), (1385, 10)]
        for (index, day) in before.enumerated() where day.0 > 0 {
            rows += spread(split(day.0), takes: day.1, seconds: day.0 * 60 / 145, on: today.adding(index - 13))
        }
        let earlier = [900, 1240, 0, 760, 1480, 320, 1110, 0, 980, 640]
        for back in 14..<46 {
            let words = earlier[back % earlier.count]
            if words > 0 { rows += spread(split(words), takes: max(3, words / 140), seconds: words * 60 / 145, on: today.adding(-back)) }
        }
        return rows.sorted { $0.endedAt < $1.endedAt }
    }

    private static func split(_ words: Int) -> [(String, Int)] {
        let mail = words * 35 / 100, notes = words * 25 / 100
        return [("Slack", words - mail - notes), ("Mail", mail), ("Notes", notes)]
    }

    /// Turns one day's words-by-app into takes: every app gets at least one, the rest go to the busiest,
    /// and the day's talking time is shared out by words so the pace is the same all day.
    private static func spread(_ cells: [(String, Int)], takes: Int, seconds: Int, on day: LocalDay) -> [TakeStat] {
        var counts = cells.map { _ in 1 }
        for _ in 0..<max(0, takes - cells.count) {
            let busiest = cells.indices.max { Double(cells[$0].1) / Double(counts[$0]) < Double(cells[$1].1) / Double(counts[$1]) } ?? 0
            counts[busiest] += 1
        }
        var parts: [(app: String, words: Int)] = []
        for (cell, count) in zip(cells, counts) {
            for i in 0..<count { parts.append((cell.0, cell.1 / count + (i < cell.1 % count ? 1 : 0))) }
        }
        let total = max(parts.reduce(0) { $0 + $1.words }, 1)
        var rows: [TakeStat] = []
        var wordsSoFar = 0, secondsSoFar = 0
        for (index, part) in parts.enumerated() {
            wordsSoFar += part.words
            let upTo = Int((Double(wordsSoFar) / Double(total) * Double(seconds)).rounded())
            let hour = 9 + index * 9 / max(parts.count, 1)
            rows.append(TakeStat(
                endedAt: day.noon.addingTimeInterval(Double(hour - 12) * 3600 + Double(index) * 60), localDay: day.key, localHour: hour,
                bundleID: apps[part.app], appName: part.app, rawWords: part.words, insertedWords: part.words,
                recordingSeconds: Double(upTo - secondsSoFar), waitSeconds: 2, outcome: .inserted))
            secondsSoFar = upTo
        }
        return rows
    }
}
