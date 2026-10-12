import AppKit
import SwiftUI

/// Recorded calls: a glass list on the left; on the right the recorder, or the chosen meeting's raw transcript.
/// The main window's third tab.
struct MeetingsView: View {
    let stores: Stores
    /// The meeting on the right. Nil shows the recorder.
    @State var selection: UUID?
    @State private var search = ""
    @State private var hovered: UUID?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    @State private var copied = false
    /// A meeting opens on its raw transcript. The summary is the second tab.
    @State var tab = DetailTab.transcript
    @State private var summaryProvider: String?
    @State private var consenting: ProviderConfig?
    @State private var confirmingDeleteSummary = false
    @State private var renaming: Int?
    @State private var nameDraft = ""
    @State private var renamingAnchor: UUID?
    @Environment(\.appActions) private var actions

    enum DetailTab: Hashable { case transcript, summary }

    private var summarizer: MeetingSummarizer { stores.summarizer }
    private var store: MeetingStore { stores.meetings }
    private var controller: MeetingController { stores.meeting }
    private var settings: SettingsStore { stores.settings }

    private var filtered: [Meeting] {
        store.meetings.filter { meeting in
            search.isEmpty || meeting.title.localizedCaseInsensitiveContains(search) || meeting.lines.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    private var selected: Meeting? { selection.flatMap { store.meeting($0) } }

    var body: some View {
        HStack(spacing: 8) {
            list
            Group {
                if let meeting = selected { detail(meeting) } else { recorder }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { controller.refreshPermissions() }
        // A meeting that just stopped opens on its transcript.
        .onChange(of: controller.latest) { _, latest in if let latest { selection = latest } }
        .onChange(of: selection) { _, _ in
            tab = .transcript
            summarizer.dismissFailure()
        }
        // A summary that has just been made is shown.
        .onChange(of: selected?.summary) { old, new in if new != nil, new != old { tab = .summary } }
        .sheet(item: $consenting) { provider in
            ProviderConsentSheet(provider: provider, forMeeting: true, onDecline: { consenting = nil }) {
                consenting = nil
                summarizer.grantConsent(provider)
                if let id = selected?.id { summarizer.summarize(id, with: provider) }
            }
        }
    }

    // MARK: list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                recorderRow
                SearchField(placeholder: "Search meetings", text: $search, height: 32)
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2").font(.system(size: 24)).foregroundStyle(Tokens.labelTertiary)
                    Text(store.meetings.isEmpty ? "No meetings yet" : "Nothing matches").font(.mmBodyEmphasis)
                    Text(store.meetings.isEmpty ? "Transcribed calls show up here, newest first." : "Try a different search.")
                        .font(.mmCallout).foregroundStyle(Tokens.labelSecondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(grouped, id: \.title) { group in
                            Text(group.title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.4).foregroundStyle(Tokens.labelTertiary)
                                .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
                            ForEach(group.meetings) { row($0) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 19)
    }

    /// Always at the top of the list: opens the recorder, and says so when a recording is running.
    private var recorderRow: some View {
        let isSelected = selected == nil
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { selection = nil } label: {
            HStack(spacing: 9) {
                switch controller.state {
                case .recording(let since):
                    PulseDot().frame(width: 17)
                    Text("Recording").font(.mmBodyEmphasis)
                    Spacer(minLength: 0)
                    ElapsedTime(since: since).font(.mmMono).foregroundStyle(Tokens.labelSecondary)
                case .transcribing(_, let progress):
                    Spinner().frame(width: 17)
                    Text("Transcribing").font(.mmBodyEmphasis)
                    Spacer(minLength: 0)
                    Text("\(Int(progress * 100))%").font(.mmMono).foregroundStyle(Tokens.labelSecondary)
                case .idle:
                    Image(systemName: "record.circle").font(.system(size: 14)).foregroundStyle(isSelected ? Tokens.accentText : Tokens.labelSecondary).frame(width: 17)
                    Text("Record a meeting").font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background { if isSelected { shape.fill(Tokens.chip).overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5)) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var grouped: [(title: String, meetings: [Meeting])] {
        var groups: [(title: String, meetings: [Meeting])] = []
        for meeting in filtered {
            let title = Self.day(meeting.date)
            if groups.last?.title == title { groups[groups.count - 1].meetings.append(meeting) } else { groups.append((title, [meeting])) }
        }
        return groups
    }

    private func row(_ meeting: Meeting) -> some View {
        let isSelected = meeting.id == selected?.id
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { selection = meeting.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title).font(.mmBodyEmphasis).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(meeting.date.formatted(date: .omitted, time: .shortened)) · \(Self.length(meeting.duration))")
                    if !meeting.isTranscribed {
                        Text(isTranscribing(meeting) ? "Transcribing" : "Not transcribed").foregroundStyle(Tokens.warning)
                    }
                }
                .font(.mmSub).foregroundStyle(Tokens.labelTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .background {
                if isSelected {
                    shape.fill(Tokens.chip).overlay(shape.strokeBorder(Tokens.accentText, lineWidth: 1.5))
                } else if hovered == meeting.id {
                    shape.strokeBorder(Tokens.stroke, lineWidth: 0.5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? meeting.id : (hovered == meeting.id ? nil : hovered) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func isTranscribing(_ meeting: Meeting) -> Bool {
        if case .transcribing(let id, _) = controller.state { id == meeting.id } else { false }
    }

    // MARK: recorder

    private var recorder: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meetings").font(.system(size: 18, weight: .bold))
                Text("Record a call and get a transcript. Everything happens on this Mac.").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            }
            recorderCard
            SettingsGroup {
                SettingsRow(title: "Microphone", subtitle: "Your side of the call", showsDivider: false) {
                    if controller.microphoneAllowed {
                        StatusChip(text: "Allowed", symbol: "checkmark", color: Tokens.success, background: Tokens.successSoft)
                    } else {
                        Button("Allow…") { controller.requestMicrophone() }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                    }
                }
                if settings.meetingSource == .microphoneAndCall {
                    SettingsRow(
                        title: "System Audio Recording",
                        subtitle: settings.askedForSystemAudio
                            ? "Lets Murmur hear the other people. Audio only, never your screen. macOS doesn’t tell Murmur whether this is on, so check it in System Settings if the others are missing from a transcript."
                            : "Lets Murmur hear the other people. Audio only, never your screen."
                    ) {
                        if settings.askedForSystemAudio {
                            Button("Open Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                            .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                        } else {
                            Button("Allow…") { controller.requestSystemAudio() }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                        }
                    }
                }
                if settings.meetingSource == .microphoneAndCall, let speakers = stores.speakers {
                    SpeakersRow(speakers: speakers, settings: settings)
                }
            }
            Button("Meeting Settings…") { actions.openSettings(.meetings) }.buttonStyle(LinkButtonStyle()).padding(.leading, 4)
            HStack(spacing: 8) {
                Image(systemName: "person.2").font(.system(size: 12))
                Text("Tell the people on the call that you are recording. In many places the law requires it.")
            }
            .font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            if let error = store.saveError {
                Text(error).font(.mmCallout).foregroundStyle(Tokens.warning)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 22))
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { controller.discard() }
        } message: {
            Text("The audio recorded so far is deleted. Nothing is transcribed.")
        }
    }

    private var recorderCard: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            switch controller.state {
            case .idle:
                Text("No call right now").font(.system(size: 15, weight: .semibold))
                Text(settings.meetingSource == .microphoneAndCall
                    ? "Murmur records your mic and, with permission, the call’s audio, so it hears everyone. Transcription runs after you stop."
                    : "Murmur records your microphone only. Transcription runs after you stop.")
                    .font(.mmBody).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
                if let problem = controller.problem {
                    Text(problem).font(.mmCallout).foregroundStyle(Tokens.warning).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { controller.start() } label: { Label("Start Recording", systemImage: "record.circle") }
                        .buttonStyle(MurmurButtonStyle(kind: .primary, height: 32))
                    Text("Source:").font(.mmCallout).foregroundStyle(Tokens.labelTertiary).padding(.leading, 6)
                    GlassPopUpButton("Source", selection: bind(settings, \.meetingSource))
                    if !settings.meetingShortcut.keycaps.isEmpty {
                        Text("or press \(settings.meetingShortcut.keycaps.joined(separator: " "))").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                    }
                }
            case .recording(let since):
                HStack(spacing: 10) {
                    PulseDot(size: 9)
                    Text("Recording").font(.system(size: 15, weight: .semibold))
                    ElapsedTime(since: since).font(.system(size: 15, design: .monospaced)).foregroundStyle(Tokens.labelSecondary)
                    Spacer()
                    Text("Microphone").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                    ProgressBar(value: Double(controller.level), height: 4).frame(width: 90)
                        .accessibilityLabel("Microphone level")
                }
                Text(settings.meetingSource == .microphoneAndCall
                    ? "Recording your microphone and the call’s audio. You can close this window; stop from here or from the menu bar."
                    : "Recording your microphone. You can close this window; stop from here or from the menu bar.")
                    .font(.mmBody).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { controller.stop() } label: { Label("Stop & Transcribe", systemImage: "stop.fill") }
                        .buttonStyle(MurmurButtonStyle(kind: .recording, height: 32))
                    Button("Discard") { confirmingDiscard = true }.buttonStyle(MurmurButtonStyle(kind: .danger, height: 32))
                }
            case .transcribing(_, let progress):
                HStack(spacing: 10) {
                    Spinner(size: 12)
                    Text(controller.isSeparatingSpeakers ? "Telling the speakers apart…" : "Transcribing on this Mac · \(Int(progress * 100))%")
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                ProgressBar(value: progress)
                Text("You can close this window. The meeting opens here when it is ready.")
                    .font(.mmBody).foregroundStyle(Tokens.labelSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.elevated, in: shape)
        .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
    }

    // MARK: detail

    private func detail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Untitled meeting", text: Binding(get: { meeting.title }, set: { store.rename(meeting.id, to: $0) }))
                        .textFieldStyle(.plain).font(.system(size: 18, weight: .bold))
                        .accessibilityLabel("Meeting title")
                    Text(meta(meeting)).font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                }
                Spacer()
                if meeting.isTranscribed, !meeting.lines.isEmpty, tab == .transcript || meeting.summary != nil {
                    Button {
                        DictationController.systemCopy(tab == .summary ? (meeting.summary?.text ?? "") : meeting.text { Self.clock(meeting, $0) })
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(MurmurButtonStyle(height: 30, fontSize: 12.5))
                }
                if meeting.isTranscribed, !meeting.lines.isEmpty {
                    GlassMenuButton(items: {
                        [
                            GlassMenuItem(title: "Markdown…", detail: "Headings and bold names") { export(meeting, markdown: true) },
                            GlassMenuItem(title: "Plain text…", detail: "For email or notes") { export(meeting, markdown: false) },
                        ]
                    }) { isOpen in
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
                            Text("Export")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isOpen ? 180 : 0))
                        }
                        .font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 13).frame(height: 30).chipPill()
                        .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Pill()))
                        .contentShape(Pill())
                    }
                    .fixedSize()
                    .accessibilityLabel("Export")
                }
                if meeting.hasAudio, meeting.isTranscribed {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([store.microphoneURL(for: meeting.id)]) } label: { Label("Show Audio", systemImage: "waveform") }
                        .buttonStyle(MurmurButtonStyle(height: 30, fontSize: 12.5))
                }
                IconButton(symbol: "trash", label: "Delete meeting", tint: Tokens.recording, chip: true) { confirmingDelete = true }
            }
            if let note = meeting.note {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.warning)
                    Text(note).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if meeting.isTranscribed, !meeting.lines.isEmpty {
                RectSegments(options: [(DetailTab.transcript, "Transcript"), (DetailTab.summary, "Summary")], selection: $tab, label: "Show")
                if tab == .summary, let summary = meeting.summary {
                    summaryView(meeting, summary)
                } else {
                    if meeting.summary == nil { summarizeCard(meeting) }
                    if tab == .transcript {
                        transcript(meeting)
                    } else {
                        Text("No summary yet. The raw transcript is on the Transcript tab.").font(.mmBody).foregroundStyle(Tokens.labelTertiary)
                        Spacer(minLength: 0)
                    }
                }
            } else if meeting.isTranscribed {
                transcript(meeting)
            } else {
                waiting(meeting)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Image(systemName: "lock").font(.system(size: 12))
                Text("On this Mac only · \(meeting.hasAudio ? "audio kept" : "audio deleted, transcript kept")")
                Spacer()
            }
            .font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
        }
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 22))
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                store.delete(meeting.id)
                selection = nil
            }
        } message: {
            Text("The transcript\(meeting.hasAudio ? " and the audio are" : " is") deleted from this Mac. This can’t be undone.")
        }
    }

    private func transcript(_ meeting: Meeting) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let marked = meeting.markedLines
        return VStack(alignment: .leading, spacing: 8) {
            Text("Raw transcript · exactly as heard, never edited\(meeting.voiceCount > 0 ? " · speaker names are guesses until you rename them" : meeting.includesCallAudio ? " · “Others” is everyone on the call" : "")")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.labelSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(meeting.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Self.clock(meeting, line.start)).font(.mmMono).foregroundStyle(Tokens.labelTertiary).frame(width: 64, alignment: .leading)
                            if let label = meeting.label(for: line) {
                                speakerLabel(label, line: line, in: meeting)
                            }
                            Text(line.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if marked.contains(line.id) {
                                Label("Marked", systemImage: "flag.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.accentText)
                                    .padding(.horizontal, 7).frame(height: 20).background(Tokens.accentSoft, in: Pill())
                            }
                        }
                    }
                    if meeting.lines.isEmpty {
                        Text("Nothing was transcribed.").font(.mmBody).foregroundStyle(Tokens.labelTertiary)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.elevated, in: shape)
            .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
        }
    }

    // MARK: summary

    private func chosenProvider() -> ProviderConfig {
        let choices = summarizer.choices
        return choices.first { $0.id == summaryProvider } ?? choices.first { $0.id == summarizer.preselected.id } ?? .apple
    }

    private func providerLabel(_ provider: ProviderConfig) -> String {
        provider.kind == .localServer && !provider.model.isEmpty ? "\(provider.name) · \(provider.model)" : provider.name
    }

    /// "Summarize with": every configured provider, the ones on this Mac first, each saying where the transcript goes.
    private var providerPopUp: some View {
        let choices = summarizer.choices
        let cleanupChoice = summarizer.preselected.id
        var details: [String: String] = [:], badges: [String: AnyView] = [:]
        var disabled: Set<String> = []
        for provider in choices {
            let mine = provider.id == cleanupChoice ? "Your AI Cleanup choice" : nil
            if let reason = summarizer.unavailableReason(provider) {
                details[provider.id] = reason
                disabled.insert(provider.id)
            } else if provider.isCloud {
                details[provider.id] = "Sends the whole transcript to \(provider.recipient)"
            } else if provider.kind == .appleIntelligence {
                details[provider.id] = mine ?? "Built into macOS"
            } else {
                details[provider.id] = [provider.hostLabel, mine].compactMap { $0 }.joined(separator: " · ")
            }
            badges[provider.id] = AnyView(PlaceBadge(isLocal: provider.isLocal, cloudText: "Cloud"))
        }
        return GlassPopUpButton(
            label: "Summarize with", options: choices.map { ($0.id, providerLabel($0)) },
            selection: Binding(get: { chosenProvider().id }, set: { summaryProvider = $0 }),
            details: details, header: "Summarize with", disabled: disabled, accessories: badges)
    }

    private func startSummary(_ meeting: Meeting) {
        let provider = chosenProvider()
        if summarizer.needsConsent(provider) { consenting = provider } else { summarizer.summarize(meeting.id, with: provider) }
    }

    /// Progress while a summary is being made, or why the last attempt failed.
    @ViewBuilder private func summaryStatus(_ meeting: Meeting) -> some View {
        switch summarizer.state {
        case .working(let id, let step, let total) where id == meeting.id:
            HStack(spacing: 10) {
                Spinner(size: 12)
                Text(total > 1 ? (step == total - 1 ? "Combining the parts…" : "Summarizing part \(step + 1) of \(total - 1)…") : "Summarizing…")
                    .font(.mmBodyEmphasis)
                if total > 1 { ProgressBar(value: Double(step) / Double(total), height: 4).frame(width: 120) }
                Spacer(minLength: 0)
                Button("Cancel") { summarizer.cancel() }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
        case .failed(let id, let message) where id == meeting.id:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .medium))
                Text("No summary was made: \(message)").font(.mmCallout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.warning)
        default: EmptyView()
        }
    }

    /// Nothing is summarized until Summarize is pressed.
    private func summarizeCard(_ meeting: Meeting) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            if summarizer.isWorking(on: meeting.id) {
                summaryStatus(meeting)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "text.badge.checkmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.accentText)
                        .frame(width: 30, height: 30).background(Tokens.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Summarize this meeting?").font(.mmBodyEmphasis)
                        Text("Key points and action items. Nothing happens until you choose.").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                    }
                    Spacer(minLength: 8)
                    providerPopUp
                    Button("Summarize") { startSummary(meeting) }
                        .buttonStyle(MurmurButtonStyle(kind: .primary, height: 30, fontSize: 12.5))
                        .disabled(summarizer.isBusy || summarizer.unavailableReason(chosenProvider()) != nil)
                }
                summaryStatus(meeting)
                if summarizer.isBusy {
                    Text("Another meeting is being summarized. This one can be summarized when that is done.")
                        .font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.elevated, in: shape)
        .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
    }

    private func summaryView(_ meeting: Meeting, _ summary: MeetingSummary) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(summary.byline).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.labelSecondary)
                if !summary.isLocal { PlaceBadge(isLocal: false, cloudText: "Cloud") }
                Spacer(minLength: 8)
                providerPopUp
                Button("Regenerate") { startSummary(meeting) }
                    .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                    .disabled(summarizer.isBusy || summarizer.unavailableReason(chosenProvider()) != nil)
                    .help(summarizer.isBusy && !summarizer.isWorking(on: meeting.id) ? "Another meeting is being summarized" : "")
                Button("Delete summary") { confirmingDeleteSummary = true }.buttonStyle(MurmurButtonStyle(kind: .danger, height: 28, fontSize: 12.5))
            }
            summaryStatus(meeting)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(summary.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        let text = line.trimmingCharacters(in: .whitespaces)
                        if text.hasPrefix("- ") || text.hasPrefix("• ") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Tokens.labelTertiary)
                                Text(String(text.dropFirst(2))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 15)).lineSpacing(4)
                        } else if text.isEmpty {
                            Color.clear.frame(height: 6)
                        } else {
                            Text(text).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                        }
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.elevated, in: shape)
            .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
        }
        .confirmationDialog("Delete this summary?", isPresented: $confirmingDeleteSummary) {
            Button("Delete Summary", role: .destructive) {
                summarizer.deleteSummary(meeting.id)
                tab = .transcript
            }
        } message: {
            Text("Only the summary is deleted. The transcript stays exactly as it is.")
        }
    }

    /// "You" and "Others" are plain labels. A voice on the call is a button: click it to give that person a name.
    @ViewBuilder private func speakerLabel(_ label: String, line: MeetingLine, in meeting: Meeting) -> some View {
        let width: CGFloat = meeting.voiceCount > 0 ? 96 : 50
        if let voice = line.voice, line.speaker == .others {
            Button {
                nameDraft = meeting.speakerNames?[String(voice)] ?? ""
                renamingAnchor = line.id
                renaming = voice
            } label: {
                Text(label).font(.mmBodyEmphasis).foregroundStyle(Tokens.labelSecondary).lineLimit(1).truncationMode(.tail)
                    .frame(width: width, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename \(label)")
            .accessibilityLabel("\(label). Rename")
            .popover(isPresented: Binding(get: { renaming == voice && isFirst(line, of: voice, in: meeting) }, set: { if !$0 { renaming = nil } })) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Who is Speaker \(voice)?").font(.mmBodyEmphasis)
                    TextField("Name", text: $nameDraft).fieldChrome().frame(width: 200)
                        .onSubmit {
                            store.nameSpeaker(meeting.id, voice: voice, nameDraft)
                            renaming = nil
                        }
                    Text("Changes the label on every line by this voice. The words are not touched.").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                        .frame(width: 200, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Save") {
                            store.nameSpeaker(meeting.id, voice: voice, nameDraft)
                            renaming = nil
                        }
                        .buttonStyle(MurmurButtonStyle(kind: .primary, height: 28, fontSize: 12.5))
                    }
                }
                .padding(14)
            }
        } else {
            Text(label).font(.mmBodyEmphasis).foregroundStyle(line.speaker == .you ? Tokens.accentText : Tokens.labelSecondary)
                .frame(width: width, alignment: .leading)
        }
    }

    /// The rename popover hangs off the first line by that voice that was clicked; one anchor is enough.
    private func isFirst(_ line: MeetingLine, of voice: Int, in meeting: Meeting) -> Bool {
        renamingAnchor == line.id
    }

    /// A recording without a transcript: in progress, or waiting after a failure or a quit.
    private func waiting(_ meeting: Meeting) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            if case .transcribing(let id, let progress) = controller.state, id == meeting.id {
                HStack(spacing: 10) {
                    Spinner(size: 12)
                    Text("Transcribing on this Mac · \(Int(progress * 100))%").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                ProgressBar(value: progress)
            } else {
                Text("Not transcribed yet").font(.system(size: 15, weight: .semibold))
                Text(meeting.problem ?? (meeting.hasAudio ? "The recording is saved on this Mac." : "The recording’s audio is gone, so it can’t be transcribed."))
                    .font(.mmBody).foregroundStyle(meeting.problem == nil ? Tokens.labelSecondary : Tokens.warning).fixedSize(horizontal: false, vertical: true)
                if meeting.hasAudio {
                    Button(meeting.problem == nil ? "Transcribe" : "Try Again") { controller.transcribe(meeting.id) }
                        .buttonStyle(MurmurButtonStyle(kind: .primary, height: 30, fontSize: 12.5))
                        .disabled(!controller.state.isIdle)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.elevated, in: shape)
        .overlay(shape.strokeBorder(Tokens.stroke, lineWidth: 0.5))
    }

    /// Saves the meeting where the user chooses. The summary goes first if there is one; the transcript is as stored.
    private func export(_ meeting: Meeting, markdown: Bool) {
        let panel = NSSavePanel()
        let name = meeting.title.isEmpty ? "Meeting" : meeting.title
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + (markdown ? ".md" : ".txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let day = "\(Self.day(meeting.date)) \(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.length(meeting.duration))"
        do {
            try meeting.export(markdown: markdown, day: day) { Self.clock(meeting, $0) }.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: words

    private func meta(_ meeting: Meeting) -> String {
        var parts = ["\(Self.day(meeting.date)) \(meeting.date.formatted(date: .omitted, time: .shortened))", Self.length(meeting.duration)]
        parts.append(meeting.includesCallAudio ? "microphone and call audio" : "microphone only")
        if meeting.voiceCount > 0 { parts.append("\(meeting.voiceCount + 1) speakers") }
        if meeting.isTranscribed { parts.append("transcribed on this Mac") }
        return parts.joined(separator: " · ")
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        return calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : date.formatted(.dateTime.weekday(.wide).month().day())
    }

    static func length(_ duration: TimeInterval) -> String {
        duration < 60 ? "\(max(1, Int(duration.rounded()))) sec" : "\(Int((duration / 60).rounded())) min"
    }

    /// The time of day a line was said.
    static func clock(_ meeting: Meeting, _ start: Double) -> String {
        meeting.date.addingTimeInterval(start).formatted(date: .omitted, time: .shortened)
    }
}

/// What the recording pill shows once a meeting is done, for a few seconds.
@Observable
final class MeetingPillState {
    var finished: UUID?
    /// The "let people know" note, for the first seconds of a recording.
    var showsReminder = false
    var copiedReminder = false
    /// The pointer is resting on the pill: show the controls.
    var hovering = false
}

/// The small pill at the top of the screen while a meeting records or transcribes: proof it is running,
/// with Stop one click away. It is left out of screen shares, recordings and screenshots.
struct MeetingPillView: View {
    let stores: Stores
    let pill: MeetingPillState
    @Environment(\.appActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controller: MeetingController { stores.meeting }

    var body: some View {
        VStack(spacing: 8) {
            pillBody
            if controller.state.isRecording, pill.showsReminder, !pill.hovering { reminder }
        }
        .foregroundStyle(Tokens.label)
        .id(stores.settings.accent)
    }

    /// Shown for the first seconds: a note to paste into the call's chat, so everyone knows.
    private var reminder: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Let people know you’re recording").font(.system(size: 12.5, weight: .semibold))
                Text("“\(SettingsStore.recordingNote)”").font(.system(size: 11.5)).foregroundStyle(Tokens.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                DictationController.systemCopy(SettingsStore.recordingNote)
                pill.copiedReminder = true
            } label: { Label(pill.copiedReminder ? "Copied" : "Copy", systemImage: pill.copiedReminder ? "checkmark" : "doc.on.doc") }
                .buttonStyle(MurmurButtonStyle(height: 26, fontSize: 12))
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .frame(width: 380)
        .glassSurface(cornerRadius: 18)
        .foregroundStyle(Tokens.label)
    }

    /// "Zoom call started": offered once per call, never recorded without a yes (or an earlier "Always").
    private func callOffer(_ app: CallApp) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AppBadge(name: app.name, bundleIdentifier: app.bundleIdentifier, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.isBrowser ? "\(app.name) is using the microphone" : "\(app.name) call started").font(.system(size: 12.5, weight: .semibold))
                Text("Record and transcribe it on this Mac?").font(.system(size: 11.5)).foregroundStyle(Tokens.labelSecondary)
            }
            .fixedSize()
            Spacer(minLength: 4)
            if !app.isBrowser {
                Button("Always for \(app.name)") { controller.recordDetectedCall(always: true) }.buttonStyle(MurmurButtonStyle(height: 26, fontSize: 12))
            }
            Button("Not Now") { controller.dismissDetectedCall() }.buttonStyle(MurmurButtonStyle(height: 26, fontSize: 12))
            Button("Record") { controller.recordDetectedCall() }.buttonStyle(MurmurButtonStyle(kind: .recording, height: 26, fontSize: 12))
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
        .frame(width: 540)
        .glassSurface(cornerRadius: 18)
        .foregroundStyle(Tokens.label)
        .accessibilityElement(children: .contain)
    }

    private func control(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Tokens.onAccent : Tokens.labelSecondary)
                .frame(width: 28, height: 28)
                .background(active ? Tokens.accent : Tokens.chip, in: Circle())
                .overlay(Circle().strokeBorder(Tokens.stroke, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var pillBody: some View {
        switch controller.state {
        case .recording(let since):
            let expanded = pill.hovering
            HStack(spacing: 8) {
                if controller.isPaused {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                    Text("Paused ·").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.labelSecondary)
                } else {
                    PulseDot()
                }
                ElapsedTime(since: since).font(.mmMono)
                if controller.isMuted, !controller.isPaused {
                    Image(systemName: "mic.slash.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.warning)
                        .accessibilityLabel("Your microphone is muted")
                } else {
                    MiniLevel(level: controller.isPaused ? 0 : controller.level)
                }
                if expanded {
                    Rectangle().fill(Tokens.separator).frame(width: 1, height: 20).padding(.horizontal, 2)
                    control("flag", controller.markCount > 0 ? "Mark this moment (\(controller.markCount) marked)" : "Mark this moment") { controller.mark() }
                    control(controller.isMuted ? "mic.slash.fill" : "mic", controller.isMuted ? "Unmute my mic" : "Mute my mic", active: controller.isMuted) { controller.toggleMute() }
                    control(controller.isPaused ? "play.fill" : "pause.fill", controller.isPaused ? "Resume" : "Pause", active: controller.isPaused) { controller.togglePause() }
                    Button { controller.stop() } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                            Text("Stop & Transcribe")
                        }
                    }
                    .buttonStyle(MurmurButtonStyle(kind: .recording, height: 32, fontSize: 12.5))
                } else {
                    Button { controller.stop() } label: {
                        RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 8, height: 8)
                            .frame(width: 24, height: 24).background(Tokens.recording, in: Circle()).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop and transcribe")
                    .help("Stop and transcribe")
                }
            }
            .padding(EdgeInsets(top: 0, leading: expanded ? 16 : 14, bottom: 0, trailing: 6))
            .frame(height: expanded ? 44 : 36)
            .glassPill()
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: expanded)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(controller.isPaused ? "Murmur meeting recording, paused" : "Murmur is recording a meeting")
        case .transcribing(_, let progress):
            HStack(spacing: 9) {
                Spinner()
                Text(controller.isSeparatingSpeakers ? "Telling the speakers apart…" : "Transcribing on this Mac · \(Int(progress * 100))%")
                    .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassPill()
        case .idle:
            if let app = controller.detectedCall {
                callOffer(app)
            } else if let meeting = pill.finished.flatMap({ stores.meetings.meeting($0) }) {
                HStack(spacing: 9) {
                    Image(systemName: meeting.isTranscribed ? "checkmark" : "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(meeting.isTranscribed ? Tokens.success : Tokens.warning)
                    Text(meeting.isTranscribed ? "\(meeting.title) · \(MeetingsView.length(meeting.duration))" : "Couldn’t transcribe the meeting")
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 300).fixedSize()
                    Button("Open") {
                        pill.finished = nil
                        actions.openMeetings()
                    }
                    .buttonStyle(MurmurButtonStyle(height: 24, fontSize: 11.5))
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 6))
                .frame(height: 36)
                .glassPill()
            }
        }
    }

    /// Seven bars that move with the microphone, so a dead microphone is obvious.
    private struct MiniLevel: View {
        let level: Float
        private static let shape: [CGFloat] = [8, 14, 10, 16, 7, 12, 15]
        var body: some View {
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<7, id: \.self) { bar in
                    Pill().fill(Tokens.label.opacity(level > 0.03 ? 0.9 : 0.3))
                        .frame(width: 2, height: max(2, Self.shape[bar] * CGFloat(min(1, 0.25 + Double(level) * 1.6))))
                }
            }
            .frame(height: 16)
            .accessibilityHidden(true)
        }
    }
}

/// The speaker model: download it once, then switch telling speakers apart on or off.
struct SpeakersRow: View {
    let speakers: FluidSpeakerSeparator
    let settings: SettingsStore
    var first = false

    private var failed: Bool { if case .failed = speakers.status { true } else { false } }
    private var subtitle: String {
        switch speakers.status {
        case .installed: "Labels the people on the call “Speaker 1”, “Speaker 2”, and you can name them. Runs on this Mac."
        case .downloading: "Getting the speaker model. This happens once."
        case .notInstalled: "Needs a small speaker model, downloaded once. After that it runs on this Mac."
        case .failed(let reason): reason
        }
    }

    var body: some View {
        SettingsRow(title: "Tell speakers apart", subtitle: subtitle, subtitleColor: failed ? Tokens.warning : Tokens.labelTertiary, showsDivider: !first) {
            switch speakers.status {
            case .installed:
                Toggle("Tell speakers apart", isOn: bind(settings, \.meetingSpeakers)).toggleStyle(MurmurToggleStyle())
            case .downloading:
                Spinner(size: 12)
                Text("Downloading…").font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
            case .notInstalled, .failed:
                Button("Download · 22 MB") { Task { await speakers.download() } }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
        }
    }
}

/// Settings › Meetings.
struct MeetingsPane: View {
    let stores: Stores
    private var settings: SettingsStore { stores.settings }

    var body: some View {
        SettingsGroup(title: "Recording") {
            SettingsRow(title: "Source", subtitle: "Call audio needs System Audio Recording. It is audio only, never your screen.", showsDivider: false) {
                GlassPopUpButton("Source", selection: bind(settings, \.meetingSource))
            }
            if let speakers = stores.speakers { SpeakersRow(speakers: speakers, settings: settings) }
            SettingsRow(title: "After transcribing", subtitle: "The transcript is always kept") {
                GlassPopUpButton("After transcribing", selection: bind(settings, \.meetingAudio))
            }
        }

        SettingsGroup(title: "When a call starts") {
            SwitchRow(
                title: "Ask when a call starts", subtitle: "Zoom, Teams, Slack huddles, Discord, Webex, and a browser that starts using the microphone",
                first: true, isOn: bind(settings, \.askWhenCallStarts))
            ForEach(settings.alwaysRecordApps, id: \.self) { app in
                SettingsRow(title: CallApp.name(for: app), subtitle: "Recorded without asking") {
                    Button("Ask Again") { settings.alwaysRecordApps.removeAll { $0 == app } }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                }
            }
            SwitchRow(
                title: "Remind me to tell people I’m recording", subtitle: "Shows a one-click note you can paste in the chat",
                isOn: bind(settings, \.meetingReminder))
        }

        SettingsGroup(title: "Screen sharing") {
            SettingsRow(title: "Recording pill", subtitle: "Always left out of screen shares, recordings and screenshots", showsDivider: false) {
                StatusChip(text: "Hidden", symbol: "eye.slash", color: Tokens.success, background: Tokens.successSoft)
            }
            SwitchRow(
                title: "Hide Murmur’s main window too", subtitle: "Overview, History and Meetings stay off a shared screen",
                isOn: bind(settings, \.hidesMainWindowFromSharing))
        }

        SettingsGroup(title: "Where it is kept") {
            SettingsRow(title: "Meetings folder", subtitle: "Transcripts, summaries and any kept audio. On this Mac only.", showsDivider: false) {
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: stores.meetings.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(stores.meetings.directory)
                }
                .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
        }
    }
}
