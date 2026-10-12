import Observation
import SwiftUI

enum MainTab: Hashable { case overview, history, meetings }

@Observable
final class MainNavigation {
    var tab = MainTab.overview
}

/// The main window: Overview, History and Meetings as tabs. 1144 x 800.
struct MainWindowView: View {
    let stores: Stores
    let navigation: MainNavigation
    /// Fixed for snapshots. Otherwise the day follows the clock.
    var today: LocalDay?
    var hoveredBar: Int?
    var showsTable = false

    var body: some View {
        VStack(spacing: 0) {
            RectSegments(options: [(MainTab.overview, "Overview"), (MainTab.history, "History"), (MainTab.meetings, "Meetings")], selection: bind(navigation, \.tab), label: "View")
                .frame(height: 52)
            switch navigation.tab {
            case .overview: OverviewView(stores: stores, today: today, hovered: hoveredBar, showsTable: showsTable)
            case .history: HistoryView(stores: stores)
            case .meetings: MeetingsView(stores: stores)
            }
        }
        .frame(width: 1144, height: 800)
        .background(Tokens.windowBackground)
        .foregroundStyle(Tokens.label)
        .id(stores.settings.accent)
    }
}

/// The squared-off segmented control from the Stats board: a solid tile on the chosen segment.
struct RectSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Tokens.label : Tokens.labelSecondary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if on {
                                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                                shape.fill(Tokens.elevated).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                shape.strokeBorder(Tokens.stroke, lineWidth: 0.5)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Tokens.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Counts for a period: the big number, three tiles, the chart and where the words went.
struct OverviewView: View {
    let stores: Stores
    var today: LocalDay?
    @State var hovered: Int?
    @State var showsTable = false
    @State private var period = StatsPeriod.week
    @State private var confirmingReset = false
    @Environment(\.appActions) private var actions

    private var settings: SettingsStore { stores.settings }
    private var stats: StatsStore { stores.stats }

    var body: some View {
        Group {
            if stats.rows.isEmpty {
                FirstTakeView(settings: settings, actions: actions)
            } else {
                // Re-read once a minute so the day and the hour roll over while the window stays open.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    content(Stats.summary(
                        rows: stats.rows, period: period, today: today ?? Stats.today(context.date), typingWPM: settings.typingWPM,
                        currentHour: today == nil ? Calendar.current.component(.hour, from: context.date) : 15))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Reset stats?", isPresented: $confirmingReset) {
            Button("Reset Stats", role: .destructive) { stats.reset() }
        } message: {
            Text("This deletes the counts for \(StatsFormat.takes(stats.rows.count)) from this Mac. History is not touched. It can’t be undone.")
        }
    }

    private func content(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(summary)
            HStack(spacing: 16) {
                tile("Talking time", StatsFormat.duration(summary.talkingSeconds)) { Text("across \(StatsFormat.takes(summary.takes))") }
                tile("Speaking pace", summary.pace.map { "\(StatsFormat.number($0)) wpm" } ?? "—") {
                    Text(summary.pace == nil ? "needs a minute of talking" : "words ÷ talking time, measured")
                }
                tile("Time saved", "about \(StatsFormat.duration(summary.savedSeconds))") {
                    Text("vs typing at")
                    typingSpeedButton
                }
            }
            HStack(alignment: .top, spacing: 16) {
                chartCard(summary).frame(width: 640)
                appsCard(summary)
            }
            .frame(maxHeight: .infinity)
            footer(summary)
        }
        .padding(EdgeInsets(top: 14, leading: 32, bottom: 24, trailing: 32))
    }

    // MARK: header

    private func header(_ summary: StatsSummary) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Words dictated · \(period.phrase)").font(.system(size: 13)).foregroundStyle(Tokens.labelSecondary)
                Text(StatsFormat.number(summary.words)).font(.system(size: 56, weight: .bold)).kerning(-2).monospacedDigit()
                    .frame(height: 60)
                HStack(spacing: 6) {
                    if let delta = summary.delta, let comparison = period.comparison {
                        DeltaPill(percent: delta.percent)
                        Text("\(comparison) (\(StatsFormat.number(delta.previousWords)))")
                    }
                }
                .font(.system(size: 13)).foregroundStyle(Tokens.labelSecondary)
                .frame(height: 22)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            RectSegments(options: StatsPeriod.allCases.map { ($0, $0.label) }, selection: $period, label: "Period")
        }
    }

    // MARK: tiles

    private func tile(_ title: String, _ value: String, @ViewBuilder note: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary)
            Text(value).font(.system(size: 30, weight: .semibold)).kerning(-0.6).monospacedDigit().frame(height: 36)
            HStack(spacing: 6, content: note).font(.system(size: 12)).foregroundStyle(Tokens.labelTertiary).frame(height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }

    private static let typingSpeeds = [10, 20, 30, 40, 50, 60, 70, 80, 100, 120, 150]

    private var typingSpeedButton: some View {
        GlassMenuButton(items: {
            [.header("Your typing speed")] + Set(Self.typingSpeeds + [settings.typingWPM]).sorted().map { speed in
                GlassMenuItem(title: "\(speed) wpm", isSelected: settings.typingWPM == speed) { settings.typingWPM = speed }
            }
        }) { isOpen in
            HStack(spacing: 5) {
                Text("\(settings.typingWPM) wpm")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.accentText)
            .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 8)).frame(height: 24)
            .chipPill()
            .contentShape(Pill())
        }
        .fixedSize()
        .accessibilityLabel("Typing speed, \(settings.typingWPM) words per minute. Change")
    }

    // MARK: chart

    private var chartTitle: String {
        switch period {
        case .today: "Words per hour"
        case .week, .month: "Words per day"
        case .all: "Words per week"
        }
    }

    private func chartCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(chartTitle).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                if period == .week {
                    legend(Tokens.accent, "Last 7 days")
                    legend(Tokens.accentMuted, "7 days before")
                }
            }
            if showsTable {
                StatsTable(buckets: summary.buckets)
            } else {
                StatsChart(summary: summary, hovered: $hovered)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .cardSurface()
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(text).font(.system(size: 12)).foregroundStyle(Tokens.labelSecondary)
        }
    }

    // MARK: apps

    private func appsCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Where your words went").font(.system(size: 14, weight: .semibold))
                Text("By the app that received them").font(.system(size: 12)).foregroundStyle(Tokens.labelTertiary)
            }
            if summary.apps.isEmpty {
                Text("Nothing dictated \(period == .today ? "yet today" : "in this period").").font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary)
            }
            let most = max(summary.apps.map(\.words).max() ?? 1, 1)
            ForEach(summary.apps) { app in
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        if app.isOther {
                            Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                                .frame(width: 20, height: 20)
                                .background(Tokens.controlStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            AppBadge(name: app.name, bundleIdentifier: app.bundleID, size: 20)
                        }
                        Text(app.name).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(width: 104, alignment: .leading)
                    GeometryReader { geo in
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous).fill(Tokens.accent)
                            .frame(width: max(2, geo.size.width * CGFloat(app.words) / CGFloat(most)))
                    }
                    .frame(height: 10)
                    Text("\(Text(StatsFormat.number(app.words)).fontWeight(.semibold).foregroundStyle(Tokens.label)) · \(app.percent)%")
                        .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Tokens.labelSecondary)
                        .frame(width: 84, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(app.name): \(StatsFormat.words(app.words)), \(app.percent) percent")
            }
            Spacer(minLength: 0)
            Button(showsTable ? "Show as chart" : "Show as table") { showsTable.toggle() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tokens.labelTertiary)
                .accessibilityHint("Switches the words chart to a table of the same numbers")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: footer

    private func footer(_ summary: StatsSummary) -> some View {
        var notes: [String] = []
        if !settings.keepStats { notes.append("Keep stats is off, so new takes aren’t counted.") }
        if let since = summary.countingSince { notes.append("Counting since \(StatsFormat.day(since)).") }
        if summary.takesWithoutTiming > 0 {
            notes.append("\(StatsFormat.takes(summary.takesWithoutTiming)) from earlier History \(summary.takesWithoutTiming == 1 ? "is" : "are") left out of time saved: no timing was kept.")
        }
        return HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 11))
            Text((["Stats are daily counts kept on this Mac, no text. They stay when History is off."] + notes).joined(separator: " "))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Button("Reset stats…") { confirmingReset = true }.buttonStyle(.plain).foregroundStyle(Tokens.accentText)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).foregroundStyle(Tokens.labelTertiary)
    }
}

private extension View {
    /// A solid content card: 18 pt corners, hairline edge. Never glass.
    func cardSurface() -> some View {
        self.padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
            .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
    }
}

/// Green when up, plain gray when down. Fewer words is not a failure, so it is never red.
struct DeltaPill: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            if percent != 0 { Image(systemName: percent > 0 ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .heavy)) }
            Text("\(StatsFormat.number(abs(percent)))%").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(percent > 0 ? Tokens.success : Tokens.labelSecondary)
        .padding(.horizontal, 8).frame(height: 22)
        .background(percent > 0 ? Tokens.successSoft : Tokens.control, in: Pill())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent == 0 ? "No change" : "\(percent > 0 ? "Up" : "Down") \(abs(percent)) percent")
    }
}

// MARK: chart

/// Bars on a three-line scale. A period with nothing in it keeps a flat mark on the baseline.
struct StatsChart: View {
    let summary: StatsSummary
    @Binding var hovered: Int?

    private let height: CGFloat = 296
    private let baseline: CGFloat = 26
    private let scaleHeight: CGFloat = 190
    private let gutter: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let buckets = summary.buckets
            let slot = (geo.size.width - gutter) / CGFloat(max(buckets.count, 1))
            let barWidth = min(22, max(2, slot * 0.56))
            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { tick in
                    let y = height - baseline - scaleHeight * CGFloat(tick) / 2
                    Rectangle().fill(Tokens.separator).frame(width: geo.size.width - gutter, height: 1).offset(x: gutter, y: y)
                    Text(StatsFormat.axis(summary.axisMax * tick / 2)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Tokens.labelTertiary)
                        .frame(width: 30, alignment: .trailing).offset(y: y - 7)
                }
                ForEach(buckets) { bucket in
                    let x = gutter + slot * CGFloat(bucket.id) + (slot - barWidth) / 2
                    let barHeight = bucket.words > 0 ? max(3, scaleHeight * CGFloat(bucket.words) / CGFloat(summary.axisMax)) : 2
                    Group {
                        if bucket.words > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: min(4, barWidth / 2), topTrailingRadius: min(4, barWidth / 2), style: .continuous)
                                .fill(bucket.isComparison ? Tokens.accentMuted : Tokens.accent)
                        } else {
                            RoundedRectangle(cornerRadius: 1).fill(Tokens.separator)
                        }
                    }
                    .frame(width: barWidth, height: barHeight)
                    .offset(x: x, y: height - baseline - barHeight)
                    if hovered == bucket.id {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Tokens.accentText.opacity(0.5), lineWidth: 2)
                            .frame(width: barWidth + 6, height: barHeight + 6)
                            .offset(x: x - 3, y: height - baseline - barHeight - 3)
                    }
                    if !bucket.axisLabel.isEmpty {
                        Text(bucket.axisLabel).font(.system(size: 11, weight: bucket.isCurrent ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(bucket.isCurrent ? Tokens.label : Tokens.labelTertiary)
                            .fixedSize().frame(width: 60)
                            .offset(x: min(x + barWidth / 2 - 30, geo.size.width - 60 + 8), y: height - 18)
                    }
                }
                if let index = hovered, buckets.indices.contains(index) {
                    let bucket = buckets[index]
                    let barHeight = bucket.words > 0 ? scaleHeight * CGFloat(bucket.words) / CGFloat(summary.axisMax) : 2
                    let center = gutter + slot * CGFloat(index) + slot / 2
                    tooltip(bucket)
                        .offset(x: min(max(center - 78, gutter), geo.size.width - 200), y: max(0, height - baseline - barHeight - 76))
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int((point.x - gutter) / slot)
                    hovered = point.x >= gutter && buckets.indices.contains(index) ? index : nil
                case .ended: hovered = nil
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func tooltip(_ bucket: StatsSummary.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bucket.title).font(.system(size: 11.5)).foregroundStyle(Tokens.labelTertiary)
            Text(StatsFormat.words(bucket.words)).font(.system(size: 15, weight: .semibold))
            Text("\(StatsFormat.takes(bucket.takes)) · \(StatsFormat.duration(bucket.seconds)) talking").font(.system(size: 11.5)).foregroundStyle(Tokens.labelSecondary)
        }
        .monospacedDigit().lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .fixedSize()
        .frame(minWidth: 156, alignment: .leading)
        .glassSurface(cornerRadius: 12)
        .frame(width: 200, alignment: .leading)
        .allowsHitTesting(false)
    }

    /// The chart read out: the totals and the tallest bar.
    private var spoken: String {
        var text = "Words \(summary.period == .today ? "per hour today" : summary.period == .all ? "per week" : "per day, \(summary.period.phrase)"). Total \(StatsFormat.number(summary.words))."
        if let delta = summary.delta { text += " The period before: \(StatsFormat.number(delta.previousWords))." }
        if let top = summary.buckets.max(by: { $0.words < $1.words }), top.words > 0 { text += " Highest: \(top.title), \(StatsFormat.words(top.words))." }
        return text
    }
}

/// The chart's numbers as plain rows, newest first.
struct StatsTable: View {
    let buckets: [StatsSummary.Bucket]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(buckets.reversed()) { bucket in
                        row(bucket.title, StatsFormat.number(bucket.words), StatsFormat.number(bucket.takes), bucket.takes > 0 ? StatsFormat.duration(bucket.seconds) : "—")
                            .font(.system(size: 12.5)).foregroundStyle(bucket.isComparison ? Tokens.labelSecondary : Tokens.label)
                            .frame(height: 30)
                            .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
                            .accessibilityElement(children: .combine)
                    }
                } header: {
                    row("When", "Words", "Takes", "Talking").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(Tokens.labelTertiary)
                        .frame(height: 26).background(Tokens.elevated)
                }
            }
        }
        .frame(height: 296)
    }

    private func row(_ when: String, _ words: String, _ takes: String, _ talking: String) -> some View {
        HStack(spacing: 10) {
            Text(when).frame(maxWidth: .infinity, alignment: .leading)
            Text(words).frame(width: 90, alignment: .trailing)
            Text(takes).frame(width: 70, alignment: .trailing)
            Text(talking).frame(width: 90, alignment: .trailing)
        }
        .monospacedDigit().lineLimit(1)
    }
}

// MARK: nothing yet

/// Before the first take there is nothing to count, so there are no zeros: only where the numbers will be.
struct FirstTakeView: View {
    let settings: SettingsStore
    let actions: AppActions

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array([10, 18, 14, 26, 8, 20, 32].enumerated()), id: \.offset) { _, height in
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous).fill(Tokens.controlStrong)
                        .frame(width: 12, height: CGFloat(height))
                }
            }
            .frame(height: 40, alignment: .bottom)
            .accessibilityHidden(true)
            if settings.keepStats {
                Text("Your first take shows up here").font(.system(size: 18, weight: .semibold))
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Text(settings.behavior == .pushToTalk && !settings.shortcut.isDoubleTap ? "Hold" : "Press")
                        Text(settings.shortcut.keycaps.joined(separator: " ")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.label)
                            .padding(.horizontal, 9).frame(height: 24).chipPill()
                        Text("in any app and talk.")
                    }
                    Text("Words, talking time and time saved start counting after that.")
                }
                .font(.system(size: 13)).foregroundStyle(Tokens.labelSecondary)
                .accessibilityElement(children: .combine)
            } else {
                Text("Stats are turned off").font(.system(size: 18, weight: .semibold))
                Text("Nothing is being counted, because Keep stats is off in Settings › Privacy.")
                    .font(.system(size: 13)).foregroundStyle(Tokens.labelSecondary)
                Button("Open Privacy Settings…") { actions.openSettings(.privacy) }
                    .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
        }
        .padding(.bottom, 20)
    }
}

// MARK: dropdown

/// Today at a glance, in the menu bar dropdown. Hidden until there is a take to count.
struct StatsStrip: View {
    let stores: Stores
    var today: LocalDay?

    var body: some View {
        if !stores.stats.rows.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let day = today ?? Stats.today(context.date)
                let week = Stats.summary(rows: stores.stats.rows, period: .week, today: day, typingWPM: stores.settings.typingWPM)
                let days = week.buckets.filter { !$0.isComparison }
                let todayWords = days.last?.words ?? 0
                let tallest = max(days.map(\.words).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today").font(.system(size: 11.5)).foregroundStyle(Tokens.labelTertiary)
                        Text(todayWords > 0 ? StatsFormat.words(todayWords) : "Nothing yet").font(.system(size: 20, weight: .semibold)).kerning(-0.2).monospacedDigit()
                        Text("\(StatsFormat.number(week.words)) this week · ~\(StatsFormat.duration(week.savedSeconds)) saved")
                            .font(.system(size: 11.5)).foregroundStyle(Tokens.labelSecondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(days) { bucket in
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                                .fill(bucket.words == 0 ? Tokens.separator : bucket.isCurrent ? Tokens.accent : Tokens.accentMuted)
                                .frame(width: 12, height: bucket.words == 0 ? 2 : max(3, 34 * CGFloat(bucket.words) / CGFloat(tallest)))
                        }
                    }
                    .frame(height: 36, alignment: .bottom)
                    .accessibilityHidden(true)
                }
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
                .chipSurface(cornerRadius: 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today: \(StatsFormat.words(todayWords)). \(StatsFormat.number(week.words)) in the last 7 days, about \(StatsFormat.duration(week.savedSeconds)) saved.")
            }
        }
    }
}
