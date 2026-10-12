import Foundation
import Testing
@testable import MurmurKit

@MainActor
@Suite struct StatsTests {
    private let us = Locale(identifier: "en_US")
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")! }

    private func row(
        _ day: String, words: Int, raw: Int? = nil, seconds: Double? = 30, wait: Double? = 2, hour: Int = 10,
        app: String = "Notes", bundle: String? = "com.apple.Notes"
    ) -> TakeStat {
        TakeStat(
            endedAt: LocalDay(day).noon, localDay: day, localHour: hour, bundleID: bundle, appName: app,
            rawWords: raw ?? words, insertedWords: words, recordingSeconds: seconds, waitSeconds: wait, outcome: .inserted)
    }

    private func summary(_ rows: [TakeStat], _ period: StatsPeriod = .week, today: String = "2026-10-12", wpm: Int = 40) -> StatsSummary {
        Stats.summary(rows: rows, period: period, today: LocalDay(today), typingWPM: wpm, firstWeekday: 1, locale: us)
    }

    // MARK: words

    @Test func countsWordsNotSpaces() {
        #expect(WordCount.count("Hello there, world.") == 3)
        #expect(WordCount.count("") == 0)
        #expect(WordCount.count("  \n ") == 0)
        #expect(WordCount.count("one  two\nthree — four") == 4)
    }

    @Test func aContractionIsOneWord() {
        #expect(WordCount.count("don't") == 1)
        #expect(WordCount.count("don’t stop, it’s fine") == 4)
    }

    @Test func aHyphenatedPairIsTwoWords() {
        // The system's word breaker splits at the hyphen, so that is what gets counted.
        #expect(WordCount.count("a well-known fix") == 4)
    }

    @Test func aNumberIsOneWord() {
        #expect(WordCount.count("3.5") == 1)
        #expect(WordCount.count("It costs 3.5 dollars, or 1,200 yen in 2026") == 9)
    }

    @Test func emojiAreNotWords() {
        #expect(WordCount.count("👍") == 0)
        #expect(WordCount.count("Great job 👍 see you 🎉🎉") == 4)
    }

    @Test func japaneseAndChineseCountWithoutSpaces() {
        #expect(WordCount.count("今日はいい天気ですね。") == 6)
        #expect(WordCount.count("我今天去商店买东西。") == 6)
    }

    // MARK: days

    @Test func aDayHoldsAcrossADaylightSavingChange() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        // Clocks go back on November 1, 2026: that local day is 25 hours long.
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30)))
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30)))
        #expect(late.timeIntervalSince(early) == 24 * 3600)
        #expect(LocalDay(early, in: newYork).key == "2026-11-01")
        #expect(LocalDay(late, in: newYork).key == "2026-11-01")
        #expect(TakeStat(endedAt: late, timeZone: newYork, bundleID: nil, appName: "Notes", rawWords: 1, insertedWords: 1, recordingSeconds: 1, waitSeconds: 1, outcome: .inserted).localHour == 23)

        // Day arithmetic steps whole days over both changes.
        #expect(LocalDay("2026-10-31").adding(1).key == "2026-11-01")
        #expect(LocalDay("2026-10-31").adding(2).key == "2026-11-02")
        #expect(LocalDay("2026-03-07").adding(2).key == "2026-03-09")
        #expect(LocalDay("2026-11-02").days(since: LocalDay("2026-10-31")) == 2)
        #expect(LocalDay("2026-03-01").adding(-1).key == "2026-02-28")

        let rows = [row("2026-10-31", words: 10), row("2026-11-01", words: 20), row("2026-11-02", words: 40)]
        let days = summary(rows, .week, today: "2026-11-02").buckets.suffix(3).map(\.words)
        #expect(days == [10, 20, 40])
    }

    @Test func aTakeKeepsItsDayAfterATimeZoneChange() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo")), losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let moment = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8)))
        // The same instant is two different days in the two places.
        #expect(LocalDay(moment, in: tokyo).key == "2026-10-12")
        #expect(LocalDay(moment, in: losAngeles).key == "2026-10-11")

        let taken = TakeStat(endedAt: moment, timeZone: tokyo, bundleID: nil, appName: "Notes", rawWords: 5, insertedWords: 5, recordingSeconds: 3, waitSeconds: 1, outcome: .inserted)
        #expect(taken.localDay == "2026-10-12" && taken.localHour == 8)
        // Stored as written, so reading it back somewhere else changes nothing.
        let d = defaults()
        StatsStore(defaults: d).record(taken)
        #expect(StatsStore(defaults: d).rows.first?.localDay == "2026-10-12")

        // Two days later, at home: it is still the take from the 12th.
        #expect(summary([taken], .week, today: "2026-10-14").buckets[11].words == 5)
        // Just landed, where it is still the 11th: the take is not lost, it counts as today.
        #expect(summary([taken], .today, today: "2026-10-11").words == 5)
    }

    // MARK: delta

    @Test func deltaIsHiddenWithNothingBefore() {
        #expect(summary([row("2026-10-10", words: 500)]).delta == nil)
        // Something long ago but an empty previous period: no "∞".
        #expect(summary([row("2026-08-01", words: 90), row("2026-10-10", words: 500)]).delta == nil)
    }

    @Test func deltaIsHiddenForAPartialPreviousPeriod() {
        // The previous 7 days run Sep 29 to Oct 5. The first take ever is on Oct 2, part-way in.
        let partial = summary([row("2026-10-02", words: 400), row("2026-10-10", words: 500)])
        #expect(partial.delta == nil)
        // From the first day of the previous period on, the comparison is fair.
        let whole = summary([row("2026-09-29", words: 400), row("2026-10-10", words: 500)])
        #expect(whole.delta == StatsSummary.Delta(percent: 25, previousWords: 400))
    }

    @Test func deltaHasTheRightSignAndRounding() {
        func delta(_ now: Int, _ before: Int) -> Int? {
            summary([row("2026-09-01", words: 1), row("2026-10-01", words: before), row("2026-10-10", words: now)]).delta?.percent
        }
        #expect(delta(8412, 7511) == 12)
        #expect(delta(500, 1000) == -50)
        #expect(delta(1004, 1000) == 0)
        #expect(delta(1006, 1000) == 1)
        #expect(delta(2, 3) == -33)
        #expect(summary([row("2026-10-10", words: 5)], .all).delta == nil)
    }

    // MARK: time saved

    @Test func timeSavedIsClampedPerTake() {
        // 10 words at 40 wpm is 15 s of typing; the take took 32 s. It saves nothing, and costs the others nothing.
        #expect(Stats.savedSeconds(words: 10, recording: 30, wait: 2, typingWPM: 40) == 0)
        let slow = row("2026-10-10", words: 10, seconds: 30, wait: 2)
        let quick = row("2026-10-11", words: 80, seconds: 30, wait: 2)
        #expect(summary([slow]).savedSeconds == 0)
        #expect(summary([slow, quick]).savedSeconds == 88)
    }

    @Test func timeSavedFollowsTheTypingSpeed() {
        let rows = [row("2026-10-11", words: 80, seconds: 30, wait: 2)]
        #expect(summary(rows, wpm: 40).savedSeconds == 88)
        #expect(summary(rows, wpm: 80).savedSeconds == 28)
        #expect(summary(rows, wpm: 150).savedSeconds == 0)

        let d = defaults()
        let settings = SettingsStore(defaults: d)
        #expect(settings.typingWPM == 40 && settings.keepStats)
        settings.typingWPM = 500
        #expect(settings.typingWPM == 150)
        settings.typingWPM = 3
        #expect(settings.typingWPM == 10)
        settings.typingWPM = 65
        #expect(SettingsStore(defaults: d).typingWPM == 65)
    }

    @Test func paceNeedsAMinuteOfTalking() {
        #expect(summary([row("2026-10-11", words: 100, seconds: 59)]).pace == nil)
        // Pace is what was said over the time it took: raw words, not the cleaned-up count.
        #expect(summary([row("2026-10-11", words: 100, raw: 150, seconds: 60)]).pace == 150)
    }

    // MARK: apps

    @Test func appCountsAddUpAndTheRestFoldsIntoOther() {
        let rows = [
            row("2026-10-10", words: 50, app: "A", bundle: "a"), row("2026-10-10", words: 40, app: "B", bundle: "b"),
            row("2026-10-11", words: 30, app: "C", bundle: "c"), row("2026-10-11", words: 20, app: "D", bundle: "d"),
            row("2026-10-11", words: 7, app: "E", bundle: "e"), row("2026-10-12", words: 3, app: "F", bundle: "f"),
            row("2026-10-12", words: 25, app: "A", bundle: "a"), row("2026-10-12", words: 4, app: "No bundle", bundle: nil),
        ]
        let result = summary(rows)
        #expect(result.apps.map(\.name) == ["A", "B", "C", "D", "Other"])
        #expect(result.apps.map(\.words) == [75, 40, 30, 20, 14])
        #expect(result.apps.reduce(0) { $0 + $1.words } == result.words)
        #expect(result.apps.last?.isOther == true)
        #expect(result.apps.first?.percent == 42)

        // Four apps or fewer: no "Other".
        let few = summary(Array(rows.prefix(4)))
        #expect(few.apps.count == 4 && !few.apps.contains { $0.isOther })
    }

    @Test func anUninstalledAppGetsTheGenericIcon() {
        let gone = AppIcons.resolve("example.not.installed.\(UUID().uuidString)", locate: { _ in nil })
        #expect(gone.isGeneric && gone.image === AppIcons.generic)
        #expect(AppIcons.resolve(nil).isGeneric)
        // Finder is on every Mac.
        #expect(!AppIcons.resolve("com.apple.finder").isGeneric)
    }

    // MARK: chart

    @Test func chartScaleIsARoundNumber() {
        #expect([0, 7, 10, 11, 1906, 2000, 2001, 5001].map(Stats.axisMax) == [10, 10, 10, 20, 2000, 2000, 5000, 10000])
        #expect([0, 500, 1000, 2500, 2_000_000].map { StatsFormat.axis($0, locale: us) } == ["0", "500", "1K", "2.5K", "2M"])
    }

    @Test func eachPeriodHasItsBars() {
        let rows = [row("2026-09-20", words: 9), row("2026-10-06", words: 7), row("2026-10-12", words: 5, hour: 9), row("2026-10-12", words: 6, hour: 15)]
        let week = summary(rows, .week)
        #expect(week.buckets.count == 14 && week.buckets.filter(\.isComparison).count == 7)
        #expect(week.buckets.last?.words == 11 && week.buckets.last?.axisLabel == "Today")
        #expect(week.buckets[7].words == 7 && week.buckets[7].isComparison == false)
        #expect(week.buckets[6].words == 0)  // an empty day keeps its place

        let month = summary(rows, .month)
        #expect(month.buckets.count == 30 && !month.buckets.contains { $0.isComparison })
        #expect(month.words == 27)

        let today = summary(rows, .today)
        #expect(today.buckets.count == 24 && today.buckets[9].words == 5 && today.buckets[15].words == 6 && today.words == 11)

        // All time: one bar per week, from the week of the first take to this one.
        let all = summary(rows, .all)
        #expect(all.buckets.count == 4)
        #expect(all.buckets.map(\.words) == [9, 0, 7, 11])
        #expect(all.buckets.first?.title == "Week of Sep 20")
    }

    @Test func durationsAndNumbersAreFormatted() {
        #expect(StatsFormat.number(8412, locale: us) == "8,412")
        #expect(StatsFormat.duration(45, locale: us) == "45 sec")
        #expect(StatsFormat.duration(3480, locale: us) == "58 min")
        #expect(StatsFormat.duration(9012, locale: us) == "2h 30m")
        #expect(StatsFormat.words(1, locale: us) == "1 word")
    }

    // MARK: the mockup

    @Test func theFixtureReproducesTheMockup() {
        let rows = StatsFixture.rows()
        let week = Stats.summary(rows: rows, period: .week, today: StatsFixture.mockupToday, typingWPM: 40, locale: us)
        #expect(StatsFormat.number(week.words, locale: us) == "8,412")
        #expect(week.delta == StatsSummary.Delta(percent: 12, previousWords: 7511))
        #expect(StatsFormat.duration(week.talkingSeconds, locale: us) == "58 min")
        #expect(week.takes == 63)
        #expect(week.pace == 145)
        #expect(StatsFormat.duration(week.savedSeconds, locale: us) == "2h 30m")
        #expect(week.apps.map(\.name) == ["Slack", "Mail", "Notes", "Xcode", "Other"])
        #expect(week.apps.map(\.words) == [3120, 2040, 1610, 940, 702])
        #expect(week.apps.map(\.percent) == [37, 24, 19, 11, 8])
        #expect(week.axisMax == 2000)
        #expect(week.countingSince == nil && week.takesWithoutTiming == 0)

        // The bar the mockup hovers, and today.
        let wednesday = week.buckets[8]
        #expect(wednesday.title == "Wed, Oct 7" && wednesday.words == 1906 && wednesday.takes == 14)
        #expect(StatsFormat.duration(wednesday.seconds, locale: us) == "13 min")
        #expect(week.buckets.last?.words == 312)
        #expect(week.buckets.map(\.axisLabel) == ["T", "W", "T", "F", "S", "S", "M", "T", "W", "T", "F", "S", "S", "Today"])
        #expect(week.buckets[4].words == 0)
        #expect(week.buckets.prefix(7).reduce(0) { $0 + $1.words } == 7511)
    }

    // MARK: what gets recorded

    private struct Rig {
        let engine = FakeEngine(), insertion = FakeInsertion()
        let settings: SettingsStore, history: HistoryStore, stats: StatsStore
        let controller: DictationController

        @MainActor init(defaults d: UserDefaults, cleanup: FakeCleanup? = nil) {
            settings = SettingsStore(defaults: d)
            history = HistoryStore(defaults: d)
            stats = StatsStore(defaults: d)
            controller = DictationController(
                audio: FakeAudio(), engine: engine, insertion: insertion, permissions: FakePermissions(), settings: settings,
                cleanup: cleanup, history: history, stats: stats,
                frontmostApp: { TargetApp(name: "Notes", bundleIdentifier: "com.apple.Notes") }, copyToClipboard: { _ in },
                insertedHold: .milliseconds(5), errorHold: .milliseconds(5))
        }

        @MainActor func take(copy: Bool = false) async {
            controller.start()
            if copy { controller.stopAndCopy() } else { controller.stopAndInsert() }
            await controller.pendingWork?.value
        }
    }

    @Test func anInsertedTakeWritesOneRowWithNoText() async throws {
        let d = defaults()
        let rig = Rig(defaults: d, cleanup: FakeCleanup())
        rig.settings.mode = .cleaned
        rig.settings.cleanupEnabled = true
        rig.engine.result = .success("um hello there world")
        await rig.take()

        let row = try #require(rig.stats.rows.first)
        #expect(rig.stats.rows.count == 1)
        #expect(row.rawWords == 4 && row.insertedWords == 3)  // "Hello there, world." landed
        #expect(row.outcome == .inserted && row.appName == "Notes" && row.bundleID == "com.apple.Notes")
        #expect(row.localDay == Stats.today().key && !row.isBackfilled)
        #expect((row.recordingSeconds ?? -1) >= 0 && (row.waitSeconds ?? -1) >= 0)
        // Nothing that was said is in what gets saved.
        let saved = String(data: try #require(d.data(forKey: "takeStats")), encoding: .utf8) ?? ""
        #expect(!saved.localizedCaseInsensitiveContains("hello") && !saved.contains("world"))
        #expect(StatsStore(defaults: d).rows == rig.stats.rows)
    }

    @Test func aCopiedTakeCountsAsCopied() async {
        let rig = Rig(defaults: defaults())
        await rig.take(copy: true)
        #expect(rig.stats.rows.map(\.outcome) == [.copied])
        #expect(rig.stats.rows.first?.insertedWords == 3)
    }

    @Test func cancelledEmptyFailedAndSecureTakesWriteNothing() async {
        let rig = Rig(defaults: defaults())
        rig.controller.start()
        rig.controller.cancel()
        #expect(rig.stats.rows.isEmpty)

        rig.engine.result = .success("   ")
        await rig.take()
        rig.controller.dismissError()
        #expect(rig.stats.rows.isEmpty)

        rig.engine.result = .failure(ServiceUnavailable())
        await rig.take()
        rig.controller.dismissError()
        #expect(rig.stats.rows.isEmpty)

        rig.engine.result = .success("my password is hunter two")
        rig.insertion.isSecureInputActive = true
        await rig.take()
        #expect(rig.controller.state == .error(.secureInput))
        rig.controller.dismissError()
        #expect(rig.stats.rows.isEmpty)

        rig.insertion.isSecureInputActive = false
        rig.insertion.fails = true
        await rig.take()
        rig.controller.dismissError()
        #expect(rig.stats.rows.isEmpty)

        // And the next good take counts.
        rig.insertion.fails = false
        await rig.take()
        #expect(rig.stats.rows.count == 1)
    }

    @Test func statsKeepWorkingWithHistoryOffAndStopWhenSwitchedOff() async {
        let rig = Rig(defaults: defaults())
        rig.settings.retention = .never
        await rig.take()
        #expect(rig.history.entries.isEmpty && rig.stats.rows.count == 1)

        rig.settings.keepStats = false
        rig.controller.cancel()
        await rig.take()
        #expect(rig.stats.rows.count == 1)
    }

    @Test func aReinsertIsNotATake() async {
        let rig = Rig(defaults: defaults())
        await rig.take()
        rig.controller.cancel()
        rig.controller.reinsertLast()
        await rig.controller.pendingWork?.value
        #expect(rig.insertion.inserted.count == 2 && rig.stats.rows.count == 1)
    }

    // MARK: store

    @Test func historyIsCountedOnceAndHonestly() throws {
        let d = defaults()
        let stats = StatsStore(defaults: d)
        let utc = try #require(TimeZone(identifier: "UTC"))
        func entry(_ day: String, _ text: String, raw: String? = nil, seconds: Double) -> HistoryEntry {
            HistoryEntry(date: LocalDay(day).noon, appName: "Mail", bundleIdentifier: "com.apple.mail", mode: .cleaned, text: text, raw: raw, audioSeconds: seconds, engine: "Fake")
        }
        let history = [
            entry("2026-10-11", "Thanks for the quick turnaround.", raw: "um thanks for the quick turnaround", seconds: 40),
            entry("2026-10-10", "On my way.", seconds: 30),
            entry("2026-10-10", "On my way.", seconds: 0),  // a re-insert: no audio, not a take
        ]
        #expect(stats.backfillOnce(from: history, timeZone: utc) == 2)
        #expect(stats.rows.map(\.localDay) == ["2026-10-10", "2026-10-11"])
        #expect(stats.rows.map(\.insertedWords) == [3, 5] && stats.rows.map(\.rawWords) == [3, 6])
        #expect(stats.rows.allSatisfy { $0.isBackfilled && $0.waitSeconds == nil && $0.localHour == 12 })
        #expect(stats.backfillOnce(from: history, timeZone: utc) == 0)
        #expect(StatsStore(defaults: d).backfillOnce(from: history, timeZone: utc) == 0)

        // Talking time and pace use the audio length History kept. Time saved does not guess the wait.
        let result = summary(stats.rows)
        #expect(result.words == 8 && result.talkingSeconds == 70 && result.pace == 8)
        #expect(result.savedSeconds == 0 && result.takesWithoutTiming == 2)
        #expect(result.countingSince == LocalDay("2026-10-10"))
        #expect(summary(stats.rows, .all).countingSince == nil)
        #expect(StatsFormat.day(LocalDay("2026-10-10"), locale: us) == "Oct 10, 2026")
    }

    @Test func resetDeletesEveryRowForGood() {
        let d = defaults()
        let stats = StatsStore(defaults: d)
        stats.record(row("2026-10-10", words: 5))
        stats.reset()
        #expect(stats.rows.isEmpty && StatsStore(defaults: d).rows.isEmpty)
        // History is not read back in after a reset.
        let old = HistoryEntry(date: Date(), appName: "Notes", bundleIdentifier: nil, mode: .raw, text: "hello", raw: nil, audioSeconds: 3, engine: "Fake")
        #expect(StatsStore(defaults: d).backfillOnce(from: [old]) == 0)
    }
}
