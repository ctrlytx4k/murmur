import SwiftUI

/// Shown when the dictation shortcut stops reaching Murmur because another app took it.
/// Presented by the hotkey service once it exists; until then it is only reachable from the demo menu.
struct HotkeyConflictDialog: View {
    let settings: SettingsStore
    var onClose: () -> Void = {}
    @State private var candidate: Shortcut

    init(settings: SettingsStore, onClose: @escaping () -> Void = {}) {
        self.settings = settings
        self.onClose = onClose
        _candidate = State(initialValue: settings.shortcut)
    }

    var body: some View {
        VStack(spacing: 8) {
            AppIconTile(size: 52)
            Text("Dictation shortcut stopped working").font(.system(size: 13.5, weight: .bold)).padding(.top, 6)
            Text("Another app now uses \(settings.shortcut.spokenName). Choose a different shortcut for Murmur.")
                .font(.mmCallout).lineSpacing(2).foregroundStyle(Tokens.labelSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            KeyRecorder(shortcut: $candidate, name: "New shortcut").padding(.top, 6)
            Text("or try ⌃⌥ Space · Right ⌘").font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
            VStack(spacing: 6) {
                Button("Save Shortcut") {
                    settings.shortcut = candidate
                    onClose()
                }
                .buttonStyle(MurmurButtonStyle(kind: .primary, height: 32, fullWidth: true))
                .disabled(candidate == settings.shortcut)
                Button("Not Now", action: onClose).buttonStyle(MurmurButtonStyle(height: 32, fullWidth: true))
            }
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 22, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 280)
        .glassSurface(cornerRadius: 28)
        .foregroundStyle(Tokens.label)
    }
}

/// The update prompt. Presented by the updater once one is chosen; it never interrupts a recording.
struct UpdateAvailableView: View {
    let version: String
    let currentVersion: String
    let size: String
    let notes: String
    @Binding var installsAutomatically: Bool
    var onSkip: () -> Void = {}
    var onLater: () -> Void = {}
    var onInstall: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            AppIconTile(size: 60)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Murmur \(version) is available").font(.system(size: 15, weight: .bold))
                    Text("You have \(currentVersion) · \(size) · signed and verified before install").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("RELEASE NOTES").font(.system(size: 11, weight: .bold)).kerning(0.3).foregroundStyle(Tokens.labelTertiary)
                    Text(notes).font(.system(size: 12.5)).lineSpacing(4).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                Toggle("Install updates automatically", isOn: $installsAutomatically)
                    .toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary).tint(Tokens.accent)
                HStack(spacing: 8) {
                    Button("Skip This Version", action: onSkip).buttonStyle(LinkButtonStyle(color: Tokens.labelSecondary))
                    Spacer()
                    Button("Remind Me Later", action: onLater).buttonStyle(MurmurButtonStyle(height: 30))
                    Button("Install & Relaunch", action: onInstall).buttonStyle(MurmurButtonStyle(kind: .primary, height: 30))
                }
                .padding(.top, 4)
            }
        }
        .padding(EdgeInsets(top: 42, leading: 26, bottom: 22, trailing: 26))
        .frame(width: 560)
        .background(Tokens.windowBackground)
        .foregroundStyle(Tokens.label)
    }
}
