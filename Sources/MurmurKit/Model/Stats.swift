import Foundation
import Observation

/// Counts words the way the system's text engine finds them, not by splitting on spaces, so Japanese
/// and Chinese count properly and punctuation never counts. "don't" and "3.5" are one word each; a
/// hyphenated pair such as "well-known" is two; an emoji on its own is none.
public nonisolated enum WordCount {
    public static func count(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
}

/// A calendar day as the user saw it, written "yyyy-MM-dd". Day arithmetic here never touches a time
/// zone, so a trip or a daylight saving change cannot move a take to another day.
public nonisolated struct LocalDay: Hashable, Comparable, Sendable {
    public let key: String

    public init(_ key: String) { self.key = key }

    /// The day it is at `date` for someone in `zone`.
    public init(_ date: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Noon UTC on this day: a fixed point for arithmetic and for formatting with a UTC formatter.
    public var noon: Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        return Self.utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) ?? .distantPast
    }

    public func adding(_ days: Int) -> LocalDay {
        LocalDay(noon.addingTimeInterval(Double(days) * 86_400), in: Self.utc.timeZone)
    }

    public func days(since other: LocalDay) -> Int {
        Int((noon.timeIntervalSince(other.noon) / 86_400).rounded())
    }

    /// The first day of this day's week. `firstWeekday` is 1 for Sunday, 2 for Monday, as in Calendar.
    public func weekStart(firstWeekday: Int) -> LocalDay {
        let weekday = Self.utc.component(.weekday, from: noon)
        return adding(-((weekday - firstWeekday + 7) % 7))
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool { a.key < b.key }
}

/// One finished take, as numbers. Never the text: stats keep working when History keeps nothing.
public nonisolated struct TakeStat: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case inserted, copied }

    public var id = UUID()
    public var endedAt: Date
    /// "yyyy-MM-dd" where the user was when the text landed. Stored, never worked out again later.
    public var localDay: String
    /// The hour on the user's clock at that moment, 0...23, kept for the same reason.
    public var localHour: Int
    /// The app that received the text.
    public var bundleID: String?
    public var appName: String
    /// Words the speech model heard.
    public var rawWords: Int
    /// Words that actually landed, after cleanup and snippets.
    public var insertedWords: Int
    /// From recording start to stop. Nil only for a row rebuilt from History that had no audio length.
    public var recordingSeconds: Double?
    /// From stop to the text landing. Nil for rows rebuilt from History, which never kept it.
    public var waitSeconds: Double?
    public var outcome: Outcome
    /// Rebuilt once from History rather than measured as the take happened.
    public var isBackfilled = false

    public init(
        endedAt: Date, timeZone: TimeZone, bundleID: String?, appName: String, rawWords: Int, insertedWords: Int,
        recordingSeconds: Double?, waitSeconds: Double?, outcome: Outcome, isBackfilled: Bool = false
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.init(
            endedAt: endedAt, localDay: LocalDay(endedAt, in: timeZone).key, localHour: calendar.component(.hour, from: endedAt),
            bundleID: bundleID, appName: appName, rawWords: rawWords, insertedWords: insertedWords,
            recordingSeconds: recordingSeconds, waitSeconds: waitSeconds, outcome: outcome, isBackfilled: isBackfilled)
    }

    public init(
        endedAt: Date, localDay: String, localHour: Int, bundleID: String?, appName: String, rawWords: Int, insertedWords: Int,
        recordingSeconds: Double?, waitSeconds: Double?, outcome: Outcome, isBackfilled: Bool = false
    ) {
        self.endedAt = endedAt
        self.localDay = localDay
        self.localHour = localHour
        self.bundleID = bundleID
        self.appName = appName
        self.rawWords = rawWords
        self.insertedWords = insertedWords
        self.recordingSeconds = recordingSeconds
        self.waitSeconds = waitSeconds
        self.outcome = outcome
        self.isBackfilled = isBackfilled
    }

    public var day: LocalDay { LocalDay(localDay) }
}

/// One row per take, oldest first. On this Mac only, no text.
@Observable
public final class StatsStore {
    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var rows: [TakeStat] { didSet { defaults.set(try? JSONEncoder().encode(rows), forKey: "takeStats") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rows = defaults.data(forKey: "takeStats").flatMap { try? JSONDecoder().decode([TakeStat].self, from: $0) } ?? []
    }

    public func record(_ row: TakeStat) { rows.append(row) }

    /// Deletes every row. History is not touched, and is not read back in afterwards.
    public func reset() {
        defaults.set(true, forKey: "takeStatsBackfilled")
        rows = []
    }

    func replaceAll(_ new: [TakeStat]) { rows = new }

    /// Rebuilds rows from what History already holds, once. History knows when, where and the final text;
    /// it does not know how long the wait was, so those rows stay out of time saved. A re-inserted entry
    /// has no audio and was not a take, so it is skipped. Returns how many rows were added.
    @discardableResult
    public func backfillOnce(from history: [HistoryEntry], timeZone: TimeZone = .current) -> Int {
        guard !defaults.bool(forKey: "takeStatsBackfilled") else { return 0 }
        defaults.set(true, forKey: "takeStatsBackfilled")
        let rebuilt = history.filter { $0.audioSeconds > 0 }.map { entry in
            TakeStat(
                endedAt: entry.date, timeZone: timeZone, bundleID: entry.bundleIdentifier, appName: entry.appName,
                rawWords: WordCount.count(entry.raw ?? entry.text), insertedWords: WordCount.count(entry.text),
                recordingSeconds: entry.audioSeconds, waitSeconds: nil, outcome: .inserted, isBackfilled: true)
        }
        guard !rebuilt.isEmpty else { return 0 }
        rows = (rows + rebuilt).sorted { $0.endedAt < $1.endedAt }
        return rebuilt.count
    }
}

// MARK: the numbers

public nonisolated enum StatsPeriod: String, CaseIterable, Sendable {
    case today, week, month, all

    public var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All time"
        }
    }

    /// As in "Words dictated · last 7 days".
    public var phrase: String {
        switch self {
        case .today: "today"
        case .week: "last 7 days"
        case .month: "last 30 days"
        case .all: "all time"
        }
    }

    /// What the delta compares against, as in "vs the 7 days before".
    public var comparison: String? {
        switch self {
        case .today: "vs yesterday"
        case .week: "vs the 7 days before"
        case .month: "vs the 30 days before"
        case .all: nil
        }
    }

    /// Days in the period, counting today. All time has no fixed length.
    public var length: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

public nonisolated struct StatsSummary: Equatable, Sendable {
    public struct Delta: Equatable, Sendable {
        /// Whole percent against the previous period, signed.
        public var percent: Int
        public var previousWords: Int
    }

    public struct AppShare: Equatable, Identifiable, Sendable {
        public var id: String
        public var bundleID: String?
        public var name: String
        public var words: Int
        /// Whole percent of the period's words.
        public var percent: Int
        /// Everything after the top four, folded together.
        public var isOther = false
    }

    public struct Bucket: Equatable, Identifiable, Sendable {
        public var id: Int
        /// Under the bar. Empty where there is no room for a label.
        public var axisLabel: String
        /// For the tooltip and the table: "Wed, Oct 7".
        public var title: String
        public var words = 0
        public var takes = 0
        public var seconds = 0.0
        /// One of the "7 days before" bars.
        public var isComparison = false
        /// The bar that is still filling up: today, this hour or this week.
        public var isCurrent = false
    }

    public var period: StatsPeriod
    /// Sum of inserted words. The big number.
    public var words = 0
    public var takes = 0
    public var talkingSeconds = 0.0
    /// Raw words per minute of talking. Nil under a minute of talking: too little to call a pace.
    public var pace: Int?
    public var savedSeconds = 0.0
    public var typingWPM: Int
    /// Nil whenever the comparison would be unfair or meaningless.
    public var delta: Delta?
    public var apps: [AppShare] = []
    public var buckets: [Bucket] = []
    /// The top of the chart's scale: 1, 2 or 5 times a power of ten.
    public var axisMax = 10
    /// Set when the first take ever is newer than the start of the period.
    public var countingSince: LocalDay?
    /// Takes in the period with no wait on record (rebuilt from History), left out of time saved.
    public var takesWithoutTiming = 0
}

public nonisolated enum Stats {
    public static func today(_ now: Date = Date(), in zone: TimeZone = .current) -> LocalDay { LocalDay(now, in: zone) }

    public static func summary(
        rows: [TakeStat], period: StatsPeriod, today: LocalDay, typingWPM: Int,
        currentHour: Int = 23, firstWeekday: Int = Calendar.current.firstWeekday, locale: Locale = .current
    ) -> StatsSummary {
        var summary = StatsSummary(period: period, typingWPM: typingWPM)
        // A take can carry a day later than today after flying west. It still counts, as today.
        let dated = rows.map { (row: $0, day: min($0.day, today)) }
        let firstDay = dated.map(\.day).min()
        let start = period.length.map { today.adding(1 - $0) } ?? firstDay ?? today
        let current = dated.filter { $0.day >= start }.map(\.row)

        summary.words = current.reduce(0) { $0 + $1.insertedWords }
        summary.takes = current.count
        summary.talkingSeconds = current.reduce(0) { $0 + ($1.recordingSeconds ?? 0) }
        let measured = current.filter { $0.recordingSeconds != nil }
        let measuredSeconds = measured.reduce(0) { $0 + ($1.recordingSeconds ?? 0) }
        if measuredSeconds >= 60 {
            summary.pace = Int((Double(measured.reduce(0) { $0 + $1.rawWords }) / (measuredSeconds / 60)).rounded())
        }
        for row in current {
            guard let recording = row.recordingSeconds, let wait = row.waitSeconds else {
                summary.takesWithoutTiming += 1
                continue
            }
            summary.savedSeconds += savedSeconds(words: row.insertedWords, recording: recording, wait: wait, typingWPM: typingWPM)
        }

        if let length = period.length, let firstDay {
            let previousStart = start.adding(-length)
            let previousWords = dated.filter { $0.day >= previousStart && $0.day < start }.reduce(0) { $0 + $1.row.insertedWords }
            // Only against a whole earlier period with something in it. Never "∞", never a percent of a part.
            if previousWords > 0, firstDay <= previousStart {
                let change = Double(summary.words - previousWords) / Double(previousWords) * 100
                summary.delta = StatsSummary.Delta(percent: Int(change.rounded()), previousWords: previousWords)
            }
            if firstDay > start { summary.countingSince = firstDay }
        }

        summary.apps = apps(current, total: summary.words)
        summary.buckets = buckets(dated, period: period, today: today, start: start, currentHour: currentHour, firstWeekday: firstWeekday, locale: locale)
        summary.axisMax = axisMax(summary.buckets.map(\.words).max() ?? 0)
        return summary
    }

    /// What typing the same words would have cost, less the time spent talking and waiting. Never negative:
    /// a slow take saves nothing, it does not take time away from the others.
    public static func savedSeconds(words: Int, recording: Double, wait: Double, typingWPM: Int) -> Double {
        max(0, Double(words) / Double(max(typingWPM, 1)) * 60 - recording - wait)
    }

    /// The smallest of 1, 2 or 5 times a power of ten that fits the tallest bar. At least 10.
    public static func axisMax(_ tallest: Int) -> Int {
        var scale = 10
        while true {
            for step in [1, 2, 5] where step * scale >= tallest { return step * scale }
            scale *= 10
        }
    }

    /// Words by receiving app, largest first: the top four and "Other". The counts add up to `total`.
    static func apps(_ rows: [TakeStat], total: Int) -> [StatsSummary.AppShare] {
        var order: [String] = []
        var byApp: [String: StatsSummary.AppShare] = [:]
        for row in rows {
            let key = row.bundleID ?? "name:\(row.appName)"
            if byApp[key] == nil { order.append(key) }
            var share = byApp[key] ?? StatsSummary.AppShare(id: key, bundleID: row.bundleID, name: row.appName, words: 0, percent: 0)
            share.words += row.insertedWords
            // The newest name wins: apps get renamed.
            share.name = row.appName
            byApp[key] = share
        }
        var shares = order.compactMap { byApp[$0] }.filter { $0.words > 0 }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if shares.count > 4 {
            let rest = shares[4...].reduce(0) { $0 + $1.words }
            shares = Array(shares[..<4]) + [StatsSummary.AppShare(id: "other", bundleID: nil, name: "Other", words: rest, percent: 0, isOther: true)]
        }
        return shares.map { share in
            var share = share
            share.percent = total > 0 ? Int((Double(share.words) / Double(total) * 100).rounded()) : 0
            return share
        }
    }

    private static func buckets(
        _ dated: [(row: TakeStat, day: LocalDay)], period: StatsPeriod, today: LocalDay, start: LocalDay,
        currentHour: Int, firstWeekday: Int, locale: Locale
    ) -> [StatsSummary.Bucket] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func text(_ day: LocalDay, _ style: Date.FormatStyle) -> String {
            var style = style
            style.timeZone = utc.timeZone
            style.locale = locale
            style.calendar = utc
            return day.noon.formatted(style)
        }
        func fill(_ bucket: inout StatsSummary.Bucket, _ row: TakeStat) {
            bucket.words += row.insertedWords
            bucket.takes += 1
            bucket.seconds += row.recordingSeconds ?? 0
        }
        let dayTitle = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()

        switch period {
        case .today:
            var buckets = (0..<24).map { hour in
                let clock = utc.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? .distantPast
                var style = Date.FormatStyle().hour()
                style.timeZone = utc.timeZone
                style.locale = locale
                let label = clock.formatted(style)
                return StatsSummary.Bucket(id: hour, axisLabel: hour % 6 == 0 ? label : "", title: label, isCurrent: hour == currentHour)
            }
            for (row, day) in dated where day == today { fill(&buckets[min(max(row.localHour, 0), 23)], row) }
            return buckets

        case .week, .month:
            // The 7-day chart also draws the 7 days before, muted, for comparison.
            let count = period == .week ? 14 : 30
            let first = today.adding(1 - count)
            var buckets = (0..<count).map { index in
                let day = first.adding(index)
                var label = period == .week ? text(day, Date.FormatStyle().weekday(.narrow)) : ((count - 1 - index) % 5 == 0 ? text(day, Date.FormatStyle().day()) : "")
                if period == .week, day == today { label = "Today" }
                return StatsSummary.Bucket(id: index, axisLabel: label, title: text(day, dayTitle), isComparison: day < start, isCurrent: day == today)
            }
            for (row, day) in dated where day >= first { fill(&buckets[day.days(since: first)], row) }
            return buckets

        case .all:
            let first = start.weekStart(firstWeekday: firstWeekday)
            let count = today.days(since: first) / 7 + 1
            var buckets = (0..<count).map { index in
                let week = first.adding(index * 7)
                // A month name under the first week that starts in that month, when there is room.
                let startsMonth = utc.component(.day, from: week.noon) <= 7
                let label = count <= 8 ? text(week, Date.FormatStyle().month(.abbreviated).day()) : (startsMonth ? text(week, Date.FormatStyle().month(.abbreviated)) : "")
                return StatsSummary.Bucket(id: index, axisLabel: label, title: "Week of " + text(week, Date.FormatStyle().month(.abbreviated).day()), isCurrent: index == count - 1)
            }
            for (row, day) in dated { fill(&buckets[day.days(since: first) / 7], row) }
            return buckets
        }
    }
}

// MARK: formatting

/// Every number in Stats goes through here, so they are grouped and worded the same way everywhere.
public nonisolated enum StatsFormat {
    public static func number(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Chart scale labels: 0, 500, 1K, 2.5K, 1M.
    public static func axis(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.locale = locale
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            (formatter.string(from: NSNumber(value: Double(value) / divisor)) ?? "") + suffix
        }
        if value >= 1_000_000 { return scaled(1_000_000, "M") }
        if value >= 1_000 { return scaled(1_000, "K") }
        return number(value, locale: locale)
    }

    /// "45 sec", "58 min", "2h 30m". Rounded to the minute from one minute up.
    public static func duration(_ seconds: Double, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        if seconds < 59.5 {
            formatter.unitsStyle = .short
            formatter.allowedUnits = [.second]
            return formatter.string(from: seconds.rounded()) ?? ""
        }
        let minutes = (seconds / 60).rounded()
        formatter.unitsStyle = minutes < 60 ? .short : .abbreviated
        formatter.allowedUnits = minutes < 60 ? [.minute] : [.hour, .minute]
        return formatter.string(from: minutes * 60) ?? ""
    }

    public static func words(_ count: Int, locale: Locale = .current) -> String {
        "\(number(count, locale: locale)) \(count == 1 ? "word" : "words")"
    }

    public static func takes(_ count: Int, locale: Locale = .current) -> String {
        "\(number(count, locale: locale)) \(count == 1 ? "take" : "takes")"
    }

    public static func day(_ day: LocalDay, locale: Locale = .current) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day().year()
        style.timeZone = TimeZone(identifier: "UTC")!
        style.locale = locale
        return day.noon.formatted(style)
    }
}
