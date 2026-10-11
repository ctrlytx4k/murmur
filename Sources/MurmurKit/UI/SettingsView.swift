import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case hotkeys = "Hotkeys"
    case voiceEngine = "Voice Engine"
    case cleanup = "AI Cleanup"
    case dictionary = "Dictionary & Snippets"
    case privacy = "Privacy"
    case advanced = "Advanced"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hotkeys: "keyboard"
        case .voiceEngine: "waveform"
        case .cleanup: "text.badge.checkmark"
        case .dictionary: "character.book.closed"
        case .privacy: "lock"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// The small chip at the right of the pane title.
    var note: String? {
        switch self {
        case .voiceEngine: "All models run on this Mac"
        case .cleanup: "Optional · runs locally"
        default: nil
        }
    }
}

/// Which pane is showing. Shared so the dropdown can open Settings on a specific one.
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
    var dictionaryTab: DictionaryPane.Tab = .dictionary
}

/// Glass sidebar, solid content. 880 x 700.
struct SettingsView: View {
    let stores: Stores
    let navigation: SettingsNavigation
    @Environment(\.appActions) private var actions

    private var settings: SettingsStore { stores.settings }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                if navigation.pane == .dictionary {
                    DictionaryPane(stores: stores, navigation: navigation)
                } else {
                    HStack(spacing: 10) {
                        Text(navigation.pane.rawValue).font(.mmPaneTitle)
                        Spacer()
                        if let note = navigation.pane.note {
                            Text(note).font(.mmSub).foregroundStyle(Tokens.labelSecondary)
                                .padding(.horizontal, 10).frame(height: 24).chipPill()
                        }
                    }
                    .frame(height: 50).padding(.horizontal, 28)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch navigation.pane {
                            case .general: GeneralPane(stores: stores)
                            case .hotkeys: HotkeysPane(settings: settings)
                            case .voiceEngine: VoiceEnginePane(stores: stores)
                            case .cleanup: CleanupPane(stores: stores)
                            case .privacy: PrivacyPane(stores: stores)
                            case .advanced: AdvancedPane(stores: stores)
                            case .dictionary: EmptyView()
                            }
                        }
                        .padding(EdgeInsets(top: 4, leading: 28, bottom: 20, trailing: 28))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: 880, height: 700)
        .background(Tokens.windowBackground)
        .foregroundStyle(Tokens.label)
        // Accent tokens resolve at draw time; rebuilding on change repaints everything in the new accent.
        .id(settings.accent)
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights, which sit inside the sidebar.
            Color.clear.frame(height: 44)
            ForEach(SettingsPane.allCases) { item in
                sidebarRow(item.rawValue, symbol: item.symbol, selected: item == navigation.pane) { navigation.pane = item }
            }
            Rectangle().fill(Tokens.separator).frame(height: 1).padding(8)
            sidebarRow("History…", symbol: "clock", selected: false, dimmed: true) { actions.openHistory() }
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

    private func sidebarRow(_ title: String, symbol: String, selected: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(selected ? Tokens.accentText : Tokens.labelSecondary).frame(width: 17)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(dimmed ? Tokens.labelSecondary : Tokens.label)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tokens.chip)
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Two-way binding to an observable store property.
@MainActor
func bind<Root: AnyObject, Value>(_ root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>) -> Binding<Value> {
    Binding(get: { root[keyPath: keyPath] }, set: { root[keyPath: keyPath] = $0 })
}

struct SwitchRow: View {
    let title: String
    var subtitle: String? = nil
    var first = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, showsDivider: !first) {
            Toggle(title, isOn: $isOn).toggleStyle(MurmurToggleStyle())
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    let stores: Stores
    private var settings: SettingsStore { stores.settings }

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
            SwitchRow(title: "Show icon in Dock", subtitle: "Off keeps Murmur in the menu bar only", isOn: bind(settings, \.showInDock))
        }

        SettingsGroup(title: "Feedback") {
            SettingsRow(title: "Sounds", subtitle: "A soft tick on start and stop", showsDivider: false) {
                PopPicker("Sound set", selection: bind(settings, \.soundSet)).disabled(!settings.soundsEnabled)
                Toggle("Sounds", isOn: bind(settings, \.soundsEnabled)).toggleStyle(MurmurToggleStyle())
            }
            SettingsRow(title: "Overlay position", subtitle: "Falls back to screen bottom when the caret can’t be found") {
                PopPicker("Overlay position", selection: bind(settings, \.overlayPosition))
            }
            SettingsRow(
                title: "Microphone",
                subtitle: stores.controller.permissions.microphone ? "System Default follows the input chosen in System Settings" : "Microphone access is off",
                subtitleColor: stores.controller.permissions.microphone ? Tokens.labelTertiary : Tokens.warning
            ) {
                PopPicker(
                    label: "Microphone",
                    options: [(String?.none, "System Default")] + AudioDevices.inputs().map { (String?.some($0.id), $0.name) },
                    selection: bind(settings, \.microphoneID))
            }
        }

        SettingsGroup(title: "Appearance") {
            SettingsRow(title: "Accent color", subtitle: "Tints buttons, toggles and selection. Status colors never change.", showsDivider: false) {
                HStack(spacing: 9) {
                    ForEach(Accent.allCases, id: \.self) { accent in
                        let on = settings.accent == accent
                        Button {
                            settings.accent = accent
                        } label: {
                            Circle().fill(swatch(accent)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.gray.opacity(0.4), lineWidth: 0.5))
                                .padding(3)
                                .overlay { if on { Circle().strokeBorder(Tokens.accentText, lineWidth: 2) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accent.name)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .help(accent.name)
                    }
                }
            }
            SettingsRow(title: "Appearance", subtitle: "Light by default. Auto follows the system.") {
                SegmentedPicker(
                    options: [(.light, "Light"), (.dark, "Dark"), (.auto, "Auto")],
                    selection: bind(settings, \.appearance), height: 26
                )
                .frame(width: 234)
            }
        }

        SettingsGroup(title: "Updates") {
            SettingsRow(title: "Check for updates automatically", subtitle: "Downloads are signed and verified before install", showsDivider: false) {
                PopPicker("Update channel", selection: bind(settings, \.updateChannel)).disabled(!settings.checksForUpdates)
                Toggle("Check for updates automatically", isOn: bind(settings, \.checksForUpdates)).toggleStyle(MurmurToggleStyle())
            }
            SettingsRow(title: "Murmur \(AppInfo.version)", subtitle: "Update checks aren’t connected in this build yet") {
                Button("Check Now") {}.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5)).disabled(true)
            }
        }
    }

    private func swatch(_ accent: Accent) -> AnyShapeStyle {
        switch accent {
        case .clear: AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.6, green: 0.63, blue: 0.67)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .system: AnyShapeStyle(AngularGradient(colors: [.blue, .purple, .pink, .orange, .green, .blue], center: .center))
        default: AnyShapeStyle(Color(nsColor: accent.fill(dark: false)))
        }
    }
}

// MARK: Hotkeys

private struct HotkeysPane: View {
    let settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Dictation") {
            ShortcutRow(settings: settings, title: "Shortcut", subtitle: "Works in every app while Murmur is running", keyPath: \.shortcut, fallback: .optionSpace, first: true)
            SettingsRow(title: "Behavior", subtitle: settings.behavior == .pushToTalk ? "Hold to talk, release to insert" : "Press once to start, again to insert") {
                SegmentedPicker(options: [(.pushToTalk, "Push-to-talk"), (.toggle, "Toggle")], selection: bind(settings, \.behavior))
                    .frame(width: 240)
            }
            SwitchRow(
                title: "Double-tap to keep listening",
                subtitle: "Double-tap the shortcut to record hands-free; tap once more to insert",
                isOn: bind(settings, \.doubleTapToLock))
        }

        SettingsGroup(title: "Other shortcuts") {
            ShortcutRow(settings: settings, title: "Cycle mode", subtitle: "Raw → Cleaned up → Command", keyPath: \.cycleModeShortcut, fallback: Shortcut(keyCode: 46, modifiers: .option), first: true)
            ShortcutRow(settings: settings, title: "Re-insert last transcription", subtitle: nil, keyPath: \.reinsertShortcut, fallback: Shortcut(keyCode: 9, modifiers: [.control, .option]))
            ShortcutRow(settings: settings, title: "Open History", subtitle: nil, keyPath: \.historyShortcut, fallback: Shortcut(keyCode: 4, modifiers: [.control, .option]))
            SettingsRow(title: "Cancel dictation", subtitle: "Fixed while recording, so it never collides with app shortcuts") {
                Keycap(text: "esc").frame(width: 160, height: 32)
                    .background(Tokens.control, in: Pill())
                    .opacity(0.55)
                    .accessibilityLabel("Escape")
            }
        }
    }
}

/// A shortcut recorder row that explains a system conflict and offers the two ways out.
private struct ShortcutRow: View {
    let settings: SettingsStore
    let title: String
    let subtitle: String?
    let keyPath: ReferenceWritableKeyPath<SettingsStore, Shortcut>
    let fallback: Shortcut
    var first = false

    private var shortcut: Shortcut { settings[keyPath: keyPath] }
    private var conflict: String? {
        settings.acceptedConflicts.contains(shortcut.spokenName) ? nil : shortcut.systemConflict
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: title,
                subtitle: conflict == nil ? subtitle : "Conflicts with a system shortcut",
                subtitleColor: conflict == nil ? Tokens.labelTertiary : Tokens.warning,
                showsDivider: !first
            ) {
                KeyRecorder(shortcut: bind(settings, keyPath), name: title, flagged: conflict != nil)
            }
            if let conflict {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 14, weight: .medium)).foregroundStyle(Tokens.warning)
                    Text("macOS uses **\(shortcut.keycaps.joined())** to \(conflict). Using it here means one of them stops working.")
                        .font(.system(size: 12.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Use Anyway") { settings.acceptedConflicts.append(shortcut.spokenName) }
                        .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                    Button("Choose Another") { settings[keyPath: keyPath] = fallback }
                        .buttonStyle(MurmurButtonStyle(kind: .primary, height: 28, fontSize: 12.5))
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 14))
            }
        }
    }
}
