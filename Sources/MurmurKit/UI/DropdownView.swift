import SwiftUI

/// The rows of the dropdown that open in place to show their choices. One at a time.
enum DropdownSection { case model, microphone }

/// The 340 pt glass panel under the menu bar icon.
struct DropdownView: View {
    let stores: Stores
    @State var expanded: DropdownSection?
    /// Fixed for snapshots.
    var statsToday: LocalDay?
    @Environment(\.appActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Briefly true after Copy, so the button can confirm it worked.
    @State private var copied = false

    private var controller: DictationController { stores.controller }
    private var settings: SettingsStore { stores.settings }
    private var modelName: String { stores.catalog.model(settings.modelID)?.name ?? controller.engineName }
    private var languageName: String { settings.language }

    private var missing: [Permission] { controller.permissions.missing }
    private var blocked: Bool { !controller.permissions.microphone || !controller.permissions.accessibility }

    var body: some View {
        VStack(spacing: 0) {
            header
            meetingRow
            mainButton
            if controller.state.isRecording { liveCard } else { statsStrip }
            modePicker
            divider.padding(.horizontal, 10)
            infoRows
            if let last = controller.lastTranscription, !controller.state.isRecording { lastCard(last) }
            links
            permissions
            divider.padding(EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10))
            menuRows
        }
        .padding(8)
        .frame(width: 340)
        .glassSurface(cornerRadius: Tokens.Radius.panel)
        .foregroundStyle(Tokens.label)
        .id(settings.accent)
    }

    private var divider: some View { Rectangle().fill(Tokens.separator).frame(height: 1) }

    /// A meeting being recorded or transcribed is always one click away, whatever window is open.
    @ViewBuilder private var meetingRow: some View {
        let meeting = stores.meeting
        if !meeting.state.isIdle {
            HStack(spacing: 9) {
                switch meeting.state {
                case .recording(let since):
                    PulseDot()
                    Text("Recording meeting").font(.mmBodyEmphasis)
                    ElapsedTime(since: since).font(.mmMono).foregroundStyle(Tokens.labelSecondary)
                    Spacer(minLength: 0)
                    Button("Stop") {
                        meeting.stop()
                        actions.closeDropdown()
                        actions.openMeetings()
                    }
                    .buttonStyle(MurmurButtonStyle(kind: .recording, height: 24, fontSize: 12))
                case .transcribing(_, let progress):
                    Spinner()
                    Text("Transcribing meeting · \(Int(progress * 100))%").font(.mmBodyEmphasis).monospacedDigit()
                    Spacer(minLength: 0)
                    Button("Open") {
                        actions.closeDropdown()
                        actions.openMeetings()
                    }
                    .buttonStyle(MurmurButtonStyle(height: 24, fontSize: 12))
                case .idle: EmptyView()
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Tokens.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
            .padding(.bottom, 6)
        }
    }

    // MARK: header

    private var status: (dot: Color, title: String, detail: String, pulsing: Bool) {
        switch controller.state {
        case .recording: (Tokens.recording, "Listening…", settings.mode.label, true)
        case .processing: (Tokens.accent, "Transcribing…", modelName, false)
        case .inserted(let summary): (Tokens.success, summary.copied ? "Copied" : "Inserted", summary.copied ? "\(summary.wordCount) words on the clipboard" : "\(summary.wordCount) words into \(summary.appName)", false)
        case .error(let error): (error.isWarning ? Tokens.warning : Tokens.recording, "Needs attention", error.title, false)
        case .idle:
            if let first = missing.first {
                (Tokens.warning, "Needs attention", "\(first.name.lowercased()) access is off", false)
            } else {
                (Tokens.success, "Ready", "\(modelName) · \(languageName)", false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconTile(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Murmur").font(.mmBodyEmphasis)
                HStack(spacing: 6) {
                    PulseDot(color: status.dot, size: 8, pulsing: status.pulsing)
                    Text(status.title).font(.system(size: 12, weight: .medium))
                    Text("· \(status.detail)").font(.mmCallout).foregroundStyle(Tokens.labelSecondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if case .recording(let since) = controller.state {
                ElapsedTime(since: since)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokens.recording)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: start / stop

    private var mainButton: some View {
        let recording = controller.state.isRecording
        let busy = controller.state == .processing
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                // Close first: the panel holds keyboard focus, and the text has to land in the app behind it.
                actions.closeDropdown()
                controller.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recording ? "stop.fill" : "mic").font(.system(size: 14, weight: .semibold)).frame(width: 17)
                    Text(recording ? "Stop & Insert" : "Start Dictation")
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        ForEach(settings.shortcut.keycaps, id: \.self) { cap in
                            Keycap(text: cap, size: 24, background: blocked ? Tokens.control : .white.opacity(0.22))
                        }
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 2))
            }
            .buttonStyle(MurmurButtonStyle(kind: recording ? .recording : (blocked ? .secondary : .primary), height: 46, fontSize: 14, fullWidth: true))
            .disabled(blocked || busy)
            .accessibilityLabel(recording ? "Stop and insert" : "Start dictation")
            .accessibilityHint("Shortcut: \(settings.shortcut.spokenName)")

            if blocked, let first = missing.first {
                Text("Needs \(first.name.lowercased()) access to record. See below.")
                    .font(.mmSub).foregroundStyle(Tokens.labelTertiary).padding(.horizontal, 6)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 2, bottom: 10, trailing: 2))
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("LIVE").font(.system(size: 11, weight: .bold)).kerning(0.4).foregroundStyle(Tokens.recording)
                Text("· typing into \(controller.target?.name ?? "the front app") when you stop")
                    .font(.system(size: 11)).foregroundStyle(Tokens.labelSecondary).lineLimit(1)
            }
            Waveform(levels: controller.levels, maxHeight: 30, color: controller.isSilent ? Tokens.warning : Tokens.label)
            if controller.isSilent {
                Text("No sound from \(AudioDevices.displayName(for: settings.microphoneID))")
                    .font(.mmCallout).foregroundStyle(Tokens.warning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chipSurface(cornerRadius: Tokens.Radius.card)
        .padding(EdgeInsets(top: 0, leading: 2, bottom: 10, trailing: 2))
    }

    /// Today's count. The whole strip opens Overview.
    @ViewBuilder private var statsStrip: some View {
        if !stores.stats.rows.isEmpty {
            Button {
                actions.closeDropdown()
                actions.openOverview()
            } label: {
                StatsStrip(stores: stores, today: statsToday)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Overview")
            .padding(EdgeInsets(top: 0, leading: 2, bottom: 10, trailing: 2))
        }
    }

    // MARK: engine and microphone

    private var cleanupNote: String? {
        guard settings.mode == .cleaned else { return nil }
        if !settings.cleanupEnabled { return "Cleanup is turned off in Settings. Text goes in as spoken." }
        if case .unavailable(let reason) = controller.cleanupAvailability { return "\(reason). Text goes in as spoken." }
        return nil
    }

    private var modePicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Mode").fontWeight(.semibold)
                Spacer()
                Text("\(settings.cycleModeShortcut.keycaps.joined()) cycles")
            }
            .font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
            HStack(spacing: 2) {
                ForEach(DictationMode.offered, id: \.self) { mode in
                    let on = settings.mode == mode
                    Button {
                        settings.mode = mode
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode.symbol).font(.system(size: 10.5, weight: .semibold))
                            Text(mode.shortLabel).font(.system(size: 12, weight: on ? .semibold : .medium))
                        }
                        .foregroundStyle(on ? Tokens.label : Tokens.labelSecondary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background { if on { Pill().fill(Tokens.chip).overlay(Pill().strokeBorder(Tokens.stroke, lineWidth: 0.5)) } }
                        .contentShape(Pill())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Tokens.control, in: Pill())
            if let note = cleanupNote {
                // Cleaned up mode that cannot clean says so, instead of quietly inserting raw text.
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Tokens.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 10, trailing: 8))
    }

    private func chevron(open: Bool) -> some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelTertiary)
            .rotationEffect(.degrees(open ? 180 : 0))
    }

    private func toggle(_ section: DropdownSection) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded = expanded == section ? nil : section }
    }

    private var infoRows: some View {
        VStack(spacing: 0) {
            Button { toggle(.model) } label: {
                infoRow(symbol: "cpu", title: "Model") {
                    Text(modelName).lineLimit(1)
                    chevron(open: expanded == .model)
                }
            }
            .buttonStyle(HoverRowStyle())
            .accessibilityValue(expanded == .model ? "Expanded" : "Collapsed")
            if expanded == .model { modelList }

            GlassMenuButton(maxHeight: 256, items: {
                SettingsStore.languages.map { language in
                    GlassMenuItem(title: language, isSelected: settings.language == language) { settings.language = language }
                }
            }) { isOpen in
                infoRow(symbol: "globe", title: "Language") {
                    Text(languageName)
                    chevron(open: isOpen)
                }
                .background(isOpen ? Tokens.control : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }

            Button { toggle(.microphone) } label: {
                infoRow(symbol: "mic", title: "Microphone") {
                    if controller.permissions.microphone {
                        Text(AudioDevices.displayName(for: settings.microphoneID)).lineLimit(1)
                    } else {
                        Text("No access").fontWeight(.semibold).foregroundStyle(Tokens.warning)
                    }
                    chevron(open: expanded == .microphone)
                }
            }
            .buttonStyle(HoverRowStyle())
            .disabled(!controller.permissions.microphone)
            .accessibilityValue(expanded == .microphone ? "Expanded" : "Collapsed")
            if expanded == .microphone, controller.permissions.microphone { microphoneList }
        }
        .padding(.vertical, 6)
    }

    /// An expanded row's choices: indented, with a thin rule down the left.
    private func accordion(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 1, content: rows)
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(Tokens.separator).frame(width: 1) }
            .padding(EdgeInsets(top: 2, leading: 18, bottom: 6, trailing: 8))
    }

    private func choice(
        _ title: String, detail: String? = nil, selected: Bool = false, monospaced: Bool = false, accent: Bool = false, disabled: Bool = false,
        @ViewBuilder accessory: () -> some View = { EmptyView() }, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle().fill(selected ? Tokens.accent : .clear).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular, design: monospaced ? .monospaced : .default))
                        .foregroundStyle(selected || accent ? Tokens.accentText : Tokens.label)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary) }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                accessory()
            }
            .padding(.horizontal, 9)
            .frame(height: detail == nil ? 30 : 42)
            .background(selected ? Tokens.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(HoverRowStyle())
        .opacity(disabled ? 0.42 : 1)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var modelList: some View {
        accordion {
            ForEach(stores.catalog.models) { model in
                choice(model.name, detail: model.isUsable ? model.detail : "Not downloaded yet", selected: settings.modelID == model.id && model.isUsable, monospaced: true) {
                    if model.isUsable {
                        settings.modelID = model.id
                    } else {
                        actions.closeDropdown()
                        actions.openSettings(.voiceEngine)
                    }
                }
            }
            choice("Manage models…", accent: true) {
                actions.closeDropdown()
                actions.openSettings(.voiceEngine)
            }
        }
    }

    private var microphoneList: some View {
        let microphones = AudioDevices.menuOptions(saved: settings.microphoneID, savedName: settings.microphoneName)
        return accordion {
            ForEach(microphones.options, id: \.value) { option in
                let selected = settings.microphoneID == option.value
                choice(option.label, detail: microphones.details[option.value], selected: selected, disabled: microphones.disconnected.contains(option.value)) {
                    if selected { ActiveMicMeter(controller: controller) }
                } action: {
                    settings.microphoneID = option.value
                }
            }
        }
    }

    private var links: some View {
        HStack(spacing: 2) {
            link("History", "clock") { actions.openHistory() }
            link("Meetings", "person.2") { actions.openMeetings() }
            link("Dictionary", "character.book.closed") { actions.openSettings(.dictionary) }
            link("Snippets", "curlybraces") { actions.openSettings(.dictionary) }
            link("Settings", "gearshape") { actions.openSettings(nil) }
        }
        .padding(.vertical, 4)
    }

    private func link(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            actions.closeDropdown()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Tokens.label).frame(height: 19)
                Text(title).font(.mmSub).foregroundStyle(Tokens.labelSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
        }
        .buttonStyle(HoverRowStyle(cornerRadius: 14))
    }

    private func infoRow(symbol: String, title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Tokens.labelSecondary).frame(width: 16)
            Text(title).foregroundStyle(Tokens.labelSecondary)
            Spacer(minLength: 8)
            value()
        }
        .font(.mmBody)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: last transcription

    private func lastCard(_ last: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Last transcription").fontWeight(.semibold).foregroundStyle(Tokens.labelSecondary)
                Text("· \(last.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))) · \(last.appName)").foregroundStyle(Tokens.labelTertiary).lineLimit(1)
                Spacer(minLength: 4)
                ModeTag(mode: last.mode)
            }
            .font(.system(size: 11))
            Text(last.text).font(.mmBody).lineSpacing(3).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                smallButton(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", tint: copied ? Tokens.success : nil) {
                    controller.copyLast()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }
                smallButton("Re-insert", symbol: "arrow.right.to.line") {
                    actions.closeDropdown()
                    controller.reinsertLast()
                }
                smallButton("Undo", symbol: "arrow.uturn.backward") { controller.undoLast() }
                    .disabled(!controller.canUndoLast)
            }
        }
        .padding(12)
        .chipSurface(cornerRadius: Tokens.Radius.card)
        .padding(EdgeInsets(top: 0, leading: 2, bottom: 6, trailing: 2))
    }

    private func smallButton(_ title: String, symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let label = HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title)
            }
            if let tint { label.foregroundStyle(tint) } else { label }
        }
        .buttonStyle(MurmurButtonStyle(height: 30, fontSize: 12, fullWidth: true))
    }

    // MARK: permissions

    @ViewBuilder private var permissions: some View {
        if let first = missing.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 15, weight: .medium)).foregroundStyle(Tokens.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(first.name) access is off").font(.mmBodyEmphasis)
                        Text(DictationError.missing(first).message).font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Fix…") {
                        actions.closeDropdown()
                        actions.openOnboarding(first)
                    }
                    .buttonStyle(MurmurButtonStyle(height: 26, fontSize: 12.5))
                    .foregroundStyle(Tokens.accentText)
                }
                VStack(spacing: 4) {
                    ForEach(Permission.allCases, id: \.self) { permission in
                        let granted = controller.permissions.isGranted(permission)
                        HStack {
                            Text(permission.name).foregroundStyle(Tokens.labelSecondary)
                            Spacer()
                            Text(granted ? "Granted" : "Not granted").fontWeight(.semibold).foregroundStyle(granted ? Tokens.success : Tokens.warning)
                        }
                        .font(.mmCallout)
                    }
                }
                .padding(.leading, 28)
            }
            .padding(12)
            .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .padding(.horizontal, 2)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Tokens.success)
                Text("Permissions OK").font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
                Spacer()
                Text("Mic · Accessibility").font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Tokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 2)
        }
    }

    // MARK: menu

    private var menuRows: some View {
        VStack(spacing: 0) {
            menuRow("Open Overview…", shortcut: "⌘1") {
                actions.closeDropdown()
                actions.openOverview()
            }
            menuRow("About Murmur") {
                actions.closeDropdown()
                actions.showAbout()
            }
            menuRow("Check for Updates…") {
                actions.closeDropdown()
                actions.checkForUpdates()
            }
            menuRow("Quit Murmur", shortcut: "⌘Q") { actions.quit() }
        }
    }

    private func menuRow(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(Tokens.labelTertiary) }
            }
            .font(.mmBody)
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .buttonStyle(HoverRowStyle(cornerRadius: 8))
    }
}

extension DictationError {
    static func missing(_ permission: Permission) -> DictationError {
        switch permission {
        case .microphone: .microphoneDenied
        case .accessibility: .accessibilityDenied
        }
    }
}
