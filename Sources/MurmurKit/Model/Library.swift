import Foundation
import Observation

public nonisolated struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var spoken: String
    public var written: String
    /// "All apps" or a short list of app names.
    public var scope = "All apps"
}

public nonisolated struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var trigger: String
    public var text: String
    /// Uses {date}, {time} or {clipboard}.
    public var isDynamic: Bool { ["{date}", "{time}", "{clipboard}"].contains { text.contains($0) } }
}

/// Custom words and snippets. Local only.
@Observable
public final class DictionaryStore {
    @ObservationIgnored private let defaults: UserDefaults
    public var entries: [DictionaryEntry] { didSet { defaults.set(try? JSONEncoder().encode(entries), forKey: "dictionary") } }
    public var snippets: [Snippet] { didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "dictionary").flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) } ?? []
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }

    private struct Archive: Codable {
        var dictionary: [DictionaryEntry]
        var snippets: [Snippet]
    }

    public func exportJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(Archive(dictionary: entries, snippets: snippets))) ?? Data()
    }

    /// Accepts Murmur JSON, or CSV with one "spoken, written" pair per line. Returns how many entries were added.
    @discardableResult
    public func importData(_ data: Data) -> Int {
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            let newEntries = archive.dictionary.filter { new in !entries.contains { $0.spoken == new.spoken && $0.written == new.written } }
            let newSnippets = archive.snippets.filter { new in !snippets.contains { $0.trigger == new.trigger } }
            entries += newEntries
            snippets += newSnippets
            return newEntries.count + newSnippets.count
        }
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        var added = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            guard !entries.contains(where: { $0.spoken == parts[0] }) else { continue }
            entries.append(DictionaryEntry(spoken: parts[0], written: parts[1]))
            added += 1
        }
        return added
    }
}

public nonisolated struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var appName: String
    public var bundleIdentifier: String?
    public var mode: DictationMode
    /// What was inserted.
    public var text: String
    /// What the speech model heard, when cleanup changed it.
    public var raw: String?
    public var audioSeconds: Double
    public var engine: String
}

/// Past transcriptions. On this Mac only, pruned to the retention setting.
@Observable
public final class HistoryStore {
    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var entries: [HistoryEntry] { didSet { defaults.set(try? JSONEncoder().encode(entries), forKey: "history") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "history").flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    /// Newest first. Does nothing when retention is "don't keep".
    public func add(_ entry: HistoryEntry, retention: SettingsStore.Retention) {
        guard retention != .never else { return }
        entries.insert(entry, at: 0)
        prune(retention: retention, now: entry.date)
    }

    public func prune(retention: SettingsStore.Retention, now: Date = Date()) {
        guard let days = retention.days else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let kept = entries.filter { $0.date >= cutoff }
        if kept.count != entries.count { entries = kept }
    }

    public func delete(_ id: UUID) { entries.removeAll { $0.id == id } }
    public func clear() { entries = [] }
    func replaceAll(_ new: [HistoryEntry]) { entries = new }
}

/// One line in the local network log shown in Settings > Privacy.
public nonisolated struct NetworkLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var host: String
    public var reason: String
    public var bytes: Int
}

/// A local record of every request the app makes: model downloads and update checks, nothing else.
@Observable
public final class NetworkLog {
    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var entries: [NetworkLogEntry] { didSet { defaults.set(try? JSONEncoder().encode(entries), forKey: "networkLog") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "networkLog").flatMap { try? JSONDecoder().decode([NetworkLogEntry].self, from: $0) } ?? []
    }

    public func record(host: String, reason: String, bytes: Int, date: Date = Date()) {
        entries.insert(NetworkLogEntry(date: date, host: host, reason: reason, bytes: bytes), at: 0)
    }

    public func clear() { entries = [] }
}

/// A speech model the app can run, and where it stands on this Mac.
public nonisolated struct SpeechModel: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case builtIn, installed, available, downloading(Double), unavailable(String) }
    public var id: String
    public var name: String
    public var detail: String
    public var speed: Int
    public var accuracy: Int
    public var usesNeuralEngine: Bool
    public var status: Status
    public var isUsable: Bool { status == .builtIn || status == .installed }
}

/// The engines named in the project's stack, in the layout the mockup uses for its model list.
@Observable
public final class ModelCatalog {
    public private(set) var models: [SpeechModel]
    @ObservationIgnored private var timer: Timer?

    public init(parakeetStatus: SpeechModel.Status = .unavailable("Arrives with the transcription engine")) {
        models = [
            SpeechModel(id: "parakeet-v3", name: "parakeet-v3", detail: "Multilingual · about 480 MB · fastest", speed: 5, accuracy: 4, usesNeuralEngine: true, status: parakeetStatus),
            SpeechModel(id: "apple-speech", name: "apple-speechanalyzer", detail: "Built into macOS · no download", speed: 4, accuracy: 4, usesNeuralEngine: false, status: .builtIn),
        ]
    }

    public func model(_ id: String) -> SpeechModel? { models.first { $0.id == id } }

    /// Set by the app when real downloads exist. Without it (the demo), downloads are simulated.
    @ObservationIgnored public var onDownload: ((String) -> Void)?
    public var downloadsAreReal: Bool { onDownload != nil }

    public func requestDownload(_ id: String) {
        if let onDownload { onDownload(id) } else { simulateDownload(id) }
    }

    public func setStatus(_ status: SpeechModel.Status, for id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }), models[index].status != status else { return }
        models[index].status = status
    }

    /// Demo only: walks the progress bar. Real downloads belong to the transcription engine.
    func simulateDownload(_ id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }), models[index].status == .available else { return }
        models[index].status = .downloading(0)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceDownload(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advanceDownload(_ id: String) {
        guard let i = models.firstIndex(where: { $0.id == id }), case .downloading(let progress) = models[i].status else {
            timer?.invalidate()
            return
        }
        if progress >= 1 {
            models[i].status = .installed
            timer?.invalidate()
        } else {
            models[i].status = .downloading(min(1, progress + 0.03))
        }
    }

    func cancelDownload(_ id: String) {
        timer?.invalidate()
        if let index = models.firstIndex(where: { $0.id == id }) { models[index].status = .available }
    }
}
