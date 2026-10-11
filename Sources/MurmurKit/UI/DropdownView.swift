import SwiftUI

/// The 340 pt glass panel under the menu bar icon.
struct DropdownView: View {
    let controller: DictationController
    let settings: SettingsStore
    @Environment(\.appActions) private var actions

    private var missing: [Permission] { controller.permissions.missing }
    private var blocked: Bool { !controller.permissions.microphone || !controller.permissions.accessibility }

    var body: some View {
        VStack(spacing: 0) {
            header
            mainButton
            if controller.state.isRecording { liveCard }
            divider.padding(.horizontal, 10)
            infoRows
            if let last = controller.lastTranscription, !controller.state.isRecording { lastCard(last) }
            permissions
            divider.padding(EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10))
            menuRows
        }
        .padding(8)
        .frame(width: 340)
        .glassSurface(cornerRadius: Tokens.Radius.panel)
        .foregroundStyle(Tokens.label)
    }

    private var divider: some View { Rectangle().fill(Tokens.separator).frame(height: 1) }

    // MARK: header

    private var status: (dot: Color, title: String, detail: String, pulsing: Bool) {
        switch controller.state {
        case .recording: (Tokens.recording, "Listening…", controller.target.map { "typing into \($0.name)" } ?? "release to insert", true)
        case .processing: (Tokens.accent, "Transcribing…", controller.engineName, false)
        case .inserted(let summary): (Tokens.success, "Inserted", "\(summary.wordCount) words into \(summary.appName)", false)
        case .error(let error): (error.isWarning ? Tokens.warning : Tokens.recording, "Needs attention", error.title, false)
        case .idle:
            if let first = missing.first {
                (Tokens.warning, "Needs attention", "\(first.name.lowercased()) access is off", false)
            } else {
                (Tokens.success, "Ready", controller.engineName, false)
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

    // MARK: engine and microphone

    private var infoRows: some View {
        VStack(spacing: 0) {
            infoRow(symbol: "cpu", title: "Engine") {
                Text(controller.engineName)
            }
            Menu {
                Picker("Microphone", selection: Binding(get: { settings.microphoneID }, set: { settings.microphoneID = $0 })) {
                    Text("System Default").tag(String?.none)
                    ForEach(AudioDevices.inputs()) { device in Text(device.name).tag(String?.some(device.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                infoRow(symbol: "mic", title: "Microphone") {
                    if controller.permissions.microphone {
                        Text(AudioDevices.displayName(for: settings.microphoneID)).lineLimit(1)
                    } else {
                        Text("No access").fontWeight(.semibold).foregroundStyle(Tokens.warning)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelTertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(HoverRowStyle())
            .menuIndicator(.hidden)
            .disabled(!controller.permissions.microphone)
        }
        .padding(.vertical, 6)
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
                Text("· \(last.date.formatted(.relative(presentation: .named))) · \(last.appName)").foregroundStyle(Tokens.labelTertiary).lineLimit(1)
            }
            .font(.system(size: 11))
            Text(last.text).font(.mmBody).lineSpacing(3).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                smallButton("Copy", symbol: "doc.on.doc") { controller.copyLast() }
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

    private func smallButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title)
            }
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
                Text("Mic · Accessibility · Input").font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
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
            menuRow("Settings…", shortcut: "⌘,") {
                actions.closeDropdown()
                actions.openSettings()
            }
            menuRow("About Murmur") {
                actions.closeDropdown()
                actions.showAbout()
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
        case .inputMonitoring: .inputMonitoringDenied
        }
    }
}
