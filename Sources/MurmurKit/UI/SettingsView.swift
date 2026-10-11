import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case hotkeys = "Hotkeys"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hotkeys: "keyboard"
        }
    }
}

/// Glass sidebar, solid content. The mockup is 880 x 700 with seven panes; with the two MVP panes it is shorter.
struct SettingsView: View {
    let controller: DictationController
    let settings: SettingsStore
    @State var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.rawValue).font(.mmPaneTitle)
                    .frame(height: 50).padding(.horizontal, 28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch pane {
                        case .general: GeneralPane(controller: controller, settings: settings)
                        case .hotkeys: HotkeysPane(settings: settings)
                        }
                    }
                    .padding(EdgeInsets(top: 4, leading: 28, bottom: 20, trailing: 28))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: 880, height: 560)
        .background(Tokens.windowBackground)
        .foregroundStyle(Tokens.label)
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights, which sit inside the sidebar.
            Color.clear.frame(height: 44)
            ForEach(SettingsPane.allCases) { item in
                let on = item == pane
                Button {
                    pane = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 14)).foregroundStyle(on ? Tokens.accentText : Tokens.labelSecondary).frame(width: 17)
                        Text(item.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tokens.chip)
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            Text("Murmur \(AppInfo.version)\nFree and open source")
                .font(.system(size: 11)).lineSpacing(3).foregroundStyle(Tokens.labelTertiary)
                .padding(.horizontal, 10)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8))
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 19)
    }
}

private struct GeneralPane: View {
    let controller: DictationController
    let settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Startup") {
            SettingsRow(
                title: "Launch at login",
                subtitle: settings.launchAtLoginError ?? "Starts quietly in the menu bar",
                subtitleColor: settings.launchAtLoginError == nil ? Tokens.labelTertiary : Tokens.warning,
                showsDivider: false
            ) {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                    .toggleStyle(MurmurToggleStyle())
            }
        }

        SettingsGroup(title: "Microphone") {
            SettingsRow(
                title: "Input device",
                subtitle: controller.permissions.microphone ? "System Default follows the input chosen in System Settings" : "Microphone access is off",
                subtitleColor: controller.permissions.microphone ? Tokens.labelTertiary : Tokens.warning,
                showsDivider: false
            ) {
                Menu {
                    Picker("Input device", selection: Binding(get: { settings.microphoneID }, set: { settings.microphoneID = $0 })) {
                        Text("System Default").tag(String?.none)
                        ForEach(AudioDevices.inputs()) { device in Text(device.name).tag(String?.some(device.id)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 7) {
                        Text(settings.microphoneID == nil ? "System Default" : AudioDevices.displayName(for: settings.microphoneID))
                            .font(.system(size: 12.5)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .padding(EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 8))
                    .frame(height: 26)
                    .chipPill()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }

        SettingsGroup(title: "Appearance") {
            SettingsRow(title: "Appearance", subtitle: "Light by default. Auto follows the system.", showsDivider: false) {
                SegmentedPicker(
                    options: [(.light, "Light"), (.dark, "Dark"), (.auto, "Auto")],
                    selection: Binding(get: { settings.appearance }, set: { settings.appearance = $0 }),
                    height: 26
                )
                .frame(width: 234)
            }
        }
    }
}

private struct HotkeysPane: View {
    let settings: SettingsStore
    @State private var previousShortcut: Shortcut?

    var body: some View {
        SettingsGroup(title: "Dictation") {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Shortcut",
                    subtitle: settings.shortcut.systemConflict == nil ? "Works in every app while Murmur is running" : "Conflicts with a system shortcut",
                    subtitleColor: settings.shortcut.systemConflict == nil ? Tokens.labelTertiary : Tokens.warning,
                    showsDivider: false
                ) {
                    KeyRecorder(shortcut: Binding(
                        get: { settings.shortcut },
                        set: { new in
                            previousShortcut = settings.shortcut
                            settings.shortcut = new
                        }))
                }
                if let use = settings.shortcut.systemConflict { conflictBanner(use) }
            }
            SettingsRow(title: "Behavior", subtitle: settings.behavior == .pushToTalk ? "Hold to talk, release to insert" : "Press once to start, again to insert") {
                SegmentedPicker(
                    options: [(.pushToTalk, "Push-to-talk"), (.toggle, "Toggle")],
                    selection: Binding(get: { settings.behavior }, set: { settings.behavior = $0 })
                )
                .frame(width: 240)
            }
            SettingsRow(title: "Cancel dictation", subtitle: "Fixed while recording, so it never collides with app shortcuts") {
                Keycap(text: "esc").frame(width: 160, height: 32)
                    .background(Tokens.control, in: Pill())
                    .opacity(0.55)
                    .accessibilityLabel("Escape")
            }
        }
    }

    private func conflictBanner(_ use: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 14, weight: .medium)).foregroundStyle(Tokens.warning)
            Text("macOS uses **\(settings.shortcut.keycaps.joined())** to \(use). Using it here means one of them stops working.")
                .font(.system(size: 12.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Choose Another") { settings.shortcut = previousShortcut?.systemConflict == nil ? (previousShortcut ?? .optionSpace) : .optionSpace }
                .buttonStyle(MurmurButtonStyle(kind: .primary, height: 28, fontSize: 12.5))
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 14))
    }
}
