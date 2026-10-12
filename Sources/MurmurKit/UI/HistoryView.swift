import SwiftUI

/// Past transcriptions: a glass list on the left, the selected entry on the right. 1144 x 740.
struct HistoryView: View {
    enum Range: Hashable { case all, today, week }

    let stores: Stores
    @State private var search = ""
    @State private var range: Range = .all
    @State private var app: String?
    @State var selection: UUID?
    @State private var hovered: UUID?
    @State private var confirmingDelete = false

    private var history: HistoryStore { stores.history }
    private var controller: DictationController { stores.controller }

    private var filtered: [HistoryEntry] {
        let calendar = Calendar.current
        return history.entries.filter { entry in
            switch range {
            case .all: true
            case .today: calendar.isDateInToday(entry.date)
            case .week: entry.date > Date().addingTimeInterval(-7 * 86_400)
            }
        }
        .filter { app == nil || $0.appName == app }
        .filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || ($0.raw ?? "").localizedCaseInsensitiveContains(search) }
    }

    private var selected: HistoryEntry? { filtered.first { $0.id == selection } ?? filtered.first }

    var body: some View {
        HStack(spacing: 8) {
            list
            Group {
                if let entry = selected { detail(entry) } else { empty }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .frame(width: 1144, height: 740)
        .background(Tokens.windowBackground)
        .foregroundStyle(Tokens.label)
        .id(stores.settings.accent)
    }

    // MARK: list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.system(size: 15, weight: .bold))
                .frame(height: 44).padding(.leading, 88)
            VStack(spacing: 8) {
                SearchField(placeholder: "Search raw and cleaned text", text: $search, height: 32)
                HStack(spacing: 4) {
                    rangeButton("All", .all)
                    rangeButton("Today", .today)
                    rangeButton("This week", .week)
                    Spacer()
                    GlassMenuButton(items: {
                        ([String?.none] + Array(Set(history.entries.map(\.appName))).sorted().map(Optional.some)).map { name in
                            GlassMenuItem(title: name ?? "All apps", isSelected: app == name) { app = name }
                        }
                    }) { isOpen in
                        HStack(spacing: 5) {
                            Text(app ?? "All apps")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isOpen ? 180 : 0))
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.labelSecondary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Pill()))
                        .contentShape(Pill())
                    }
                    .fixedSize()
                }
            }
            .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(grouped, id: \.title) { group in
                        Text(group.title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.4).foregroundStyle(Tokens.labelTertiary)
                            .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
                        ForEach(group.entries) { row($0) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 19)
    }

    private func rangeButton(_ title: String, _ value: Range) -> some View {
        let on = range == value
        return Button { range = value } label: {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .medium)).foregroundStyle(on ? Tokens.label : Tokens.labelSecondary)
                .padding(.horizontal, 12).frame(height: 26)
                .background { if on { Pill().fill(Tokens.chip).overlay(Pill().strokeBorder(Tokens.stroke, lineWidth: 0.5)) } }
                .contentShape(Pill())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var grouped: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(title: String, entries: [HistoryEntry])] = []
        for entry in filtered {
            let title = calendar.isDateInToday(entry.date) ? "Today" : calendar.isDateInYesterday(entry.date) ? "Yesterday" : entry.date.formatted(.dateTime.weekday(.wide).month().day())
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else { groups.append((title, [entry])) }
        }
        return groups
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let isSelected = entry.id == selected?.id
        return Button {
            selection = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    AppBadge(name: entry.appName, bundleIdentifier: entry.bundleIdentifier)
                    Text(entry.appName).fontWeight(.semibold).foregroundStyle(Tokens.labelSecondary)
                    Text(entry.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(Tokens.labelTertiary)
                    ModeTag(mode: entry.mode)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                Text(entry.text).font(.mmBody).lineSpacing(3).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                if isSelected {
                    shape.fill(Tokens.chip).overlay(shape.strokeBorder(Tokens.accentText, lineWidth: 1.5))
                } else if hovered == entry.id {
                    shape.strokeBorder(Tokens.stroke, lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .overlay(alignment: .topTrailing) {
            if hovered == entry.id {
                HStack(spacing: 4) {
                    IconButton(symbol: "doc.on.doc", label: "Copy", tint: Tokens.label, chip: true) { DictationController.systemCopy(entry.text) }
                    IconButton(symbol: "arrow.right.to.line", label: "Re-insert", tint: Tokens.label, chip: true) { controller.reinsert(entry.text, mode: entry.mode) }
                }
                .padding(3).glassPill().padding(EdgeInsets(top: 7, leading: 0, bottom: 0, trailing: 8))
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: detail

    private func detail(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: entry.date)).font(.system(size: 18, weight: .bold))
                    Text(meta(entry)).font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                }
                Spacer()
                Button { DictationController.systemCopy(entry.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(MurmurButtonStyle(height: 30, fontSize: 12.5))
                    .keyboardShortcut("c", modifiers: .command)
                Button { controller.reinsert(entry.text, mode: entry.mode) } label: { Label("Re-insert", systemImage: "arrow.right.to.line") }
                    .buttonStyle(MurmurButtonStyle(kind: .primary, height: 30, fontSize: 12.5))
                    .keyboardShortcut(.return, modifiers: [])
                IconButton(symbol: "trash", label: "Delete entry", tint: Tokens.recording, chip: true) { confirmingDelete = true }
                    .keyboardShortcut(.delete, modifiers: [])
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(entry.raw == nil ? "Transcript" : "Cleaned").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.labelSecondary)
                    Text("INSERTED").font(.system(size: 9.5, weight: .bold)).kerning(0.4).foregroundStyle(Tokens.accentText)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Tokens.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(entry.text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
            }
            if let raw = entry.raw {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Raw transcript").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.labelSecondary)
                        Spacer()
                        Text("removed").strikethrough(color: Tokens.recording).foregroundStyle(Tokens.labelTertiary)
                        Text("changed").foregroundStyle(Tokens.accentText).padding(.horizontal, 5).background(Tokens.accentSoft, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .font(.mmCallout)
                    Text(TranscriptDiff.attributed(raw: raw, cleaned: entry.text))
                        .font(.system(size: 13, design: .monospaced)).lineSpacing(7)
                        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "lock").font(.system(size: 12))
                Text("On this Mac only · \(retentionText) · no audio saved")
                Spacer()
                HStack(spacing: 6) {
                    hint("↩"); Text("re-insert")
                    hint("⌘C"); Text("copy")
                    hint("⌫"); Text("delete")
                }
            }
            .font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
        }
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 22))
        .confirmationDialog("Delete this transcription?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                history.delete(entry.id)
                selection = nil
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(Tokens.labelTertiary)
            Text(history.entries.isEmpty ? "No transcriptions yet" : "Nothing matches").font(.mmTitle)
            Text(history.entries.isEmpty
                ? (stores.settings.retention == .never ? "History is turned off in Settings › Privacy." : "What you dictate shows up here, on this Mac only.")
                : "Try a different search or filter.")
                .font(.mmBody).foregroundStyle(Tokens.labelSecondary)
        }
    }

    private var retentionText: String {
        switch stores.settings.retention {
        case .never: "history is off"
        case .forever: "kept until you delete it"
        default: "kept \(stores.settings.retention.rawValue)"
        }
    }

    private func hint(_ key: String) -> some View {
        Text(key).font(.system(size: 11)).foregroundStyle(Tokens.labelSecondary).padding(.horizontal, 6).padding(.vertical, 2).chipSurface(cornerRadius: 6)
    }

    private func title(for date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : date.formatted(.dateTime.weekday(.wide).month().day())
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func meta(_ entry: HistoryEntry) -> String {
        let seconds = Int(entry.audioSeconds.rounded())
        return "Inserted into \(entry.appName) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) of audio · \(entry.engine) · \(entry.mode.label)"
    }
}

/// Marks what cleanup did to the raw transcript: words it dropped, and words it kept but re-cased or re-punctuated.
nonisolated enum TranscriptDiff {
    enum Kind { case same, removed, changed }

    static func words(raw: String, cleaned: String) -> [(word: String, kind: Kind)] {
        func key(_ s: Substring) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = raw.split(separator: " "), b = cleaned.split(separator: " ")
        let ka = a.map(key), kb = b.map(key)
        // Longest common subsequence over normalized words.
        var table = Array(repeating: Array(repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                table[i][j] = ka[i] == kb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(String, Kind)] = []
        var i = 0, j = 0
        while i < ka.count {
            if j < kb.count, ka[i] == kb[j] {
                // Added punctuation and a capital at the start of a sentence are not worth flagging.
                func bare(_ s: Substring) -> String { String(s.filter { $0.isLetter || $0.isNumber || $0 == "’" || $0 == "'" }) }
                let startsSentence = j == 0 || ".!?".contains(b[j - 1].last ?? " ")
                let same = bare(a[i]) == bare(b[j]) || (startsSentence && bare(a[i]).lowercased() == bare(b[j]).lowercased())
                out.append((String(a[i]), same ? .same : .changed))
                i += 1; j += 1
            } else if j < kb.count, table[i][j + 1] > table[i + 1][j] {
                j += 1
            } else {
                out.append((String(a[i]), .removed))
                i += 1
            }
        }
        return out
    }

    @MainActor
    static func attributed(raw: String, cleaned: String) -> AttributedString {
        var result = AttributedString()
        for (word, kind) in words(raw: raw, cleaned: cleaned) {
            var piece = AttributedString(word)
            switch kind {
            case .same: piece.foregroundColor = Tokens.labelSecondary
            case .removed:
                piece.foregroundColor = Tokens.labelTertiary
                piece.strikethroughStyle = .single
                piece.strikethroughColor = .init(Tokens.recording)
            case .changed:
                piece.foregroundColor = Tokens.accentText
                piece.backgroundColor = Tokens.accentSoft
            }
            result += piece + AttributedString(" ")
        }
        return result
    }
}
