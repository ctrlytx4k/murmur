import AppKit
import SwiftUI

/// The glass card that follows a take: listening, transcribing, inserted, or what went wrong.
/// It shows where the text is going and never takes focus.
struct OverlayView: View {
    let stores: Stores
    @Environment(\.appActions) private var actions

    private var controller: DictationController { stores.controller }
    private var settings: SettingsStore { stores.settings }
    private var cleaning: Bool { settings.mode == .cleaned && settings.cleanupEnabled && stores.controller.cleanupAvailability.isAvailable }

    var body: some View {
        Group {
            switch controller.state {
            case .recording(let since): listening(since: since)
            case .processing: processing
            case .inserted(let summary): inserted(summary)
            case .error(.modelNotReady(let name, let progress)): modelCard(name: name, progress: progress)
            case .error(let error): errorCard(error)
            case .idle: EmptyView()
            }
        }
        .foregroundStyle(Tokens.label)
        .id(settings.accent)
    }

    // MARK: listening

    private func listening(since: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                targetLabel
                Spacer()
                modeMenu
                moreMenu
            }
            .frame(height: 26)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))

            if let notice = controller.deviceNotice {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.warning)
                    Text(notice).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 2, trailing: 10))
            }

            if controller.isSilent {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash").font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.warning)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("No sound from microphone").font(.mmBodyEmphasis)
                        Text(AudioDevices.displayName(for: settings.microphoneID)).font(.mmSub).foregroundStyle(Tokens.labelSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
            } else {
                Text(controller.isLatched || settings.shortcut.isDoubleTap ? "Listening… \(settings.shortcut.keycaps.joined(separator: " ")) again to insert" : "Listening…")
                    .font(.mmTranscript).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Tokens.labelSecondary)
                    .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
            }

            HStack(spacing: 10) {
                PulseDot(pulsing: !controller.isSilent)
                Waveform(levels: controller.levels, color: controller.isSilent ? Tokens.warning : Tokens.label)
                ElapsedTime(since: since).font(.mmMono).foregroundStyle(Tokens.labelTertiary)
                HStack(spacing: 4) {
                    hintKey("esc")
                    if settings.behavior == .toggle || controller.isLatched || settings.shortcut.isDoubleTap { hintKey("↩") }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 12))
        }
        .frame(width: 400)
        .glassSurface(cornerRadius: Tokens.Radius.overlay)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Murmur is listening. Text will go into \(controller.target?.name ?? "the front app").")
    }

    // MARK: processing

    private var processing: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                targetLabel
                Spacer()
                Spinner()
                Text(cleaning ? "Cleaning up…" : "Transcribing…").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
            }
            .frame(height: 26)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 14))
            Sweep()
                .frame(height: 21)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 14, trailing: 16))
        }
        .frame(width: 400)
        .glassSurface(cornerRadius: Tokens.Radius.overlay)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcribing")
    }

    // MARK: inserted

    private func inserted(_ summary: InsertionSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.success)
                .frame(width: 30, height: 30).background(Tokens.successSoft, in: Circle())
            Text("Inserted into \(summary.appName)").font(.system(size: 13.5, weight: .semibold))
            Text("\(summary.wordCount) \(summary.wordCount == 1 ? "word" : "words")").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            HStack(spacing: 4) {
                hintKey("⌘Z")
                Text("undo").font(.system(size: 10.5)).foregroundStyle(Tokens.labelTertiary)
            }
            .padding(.leading, 4)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        .frame(height: 46)
        .glassPill()
        .accessibilityElement(children: .combine)
    }

    // MARK: error

    private func errorCard(_ error: DictationError) -> some View {
        let tint = error.isWarning ? Tokens.warning : Tokens.recording
        let soft = error.isWarning ? Tokens.warningSoft : Tokens.recordingSoft
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: error == .secureInput ? "lock.fill" : "exclamationmark")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 20, height: 20).background(soft, in: Circle())
                Text(error.title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    controller.dismissError()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                        .frame(width: 26, height: 26).chipPill()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))
            Text(error.message)
                .font(.mmBody).lineSpacing(4).foregroundStyle(Tokens.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
        }
        .frame(width: 400)
        .glassSurface(cornerRadius: Tokens.Radius.overlay)
        .accessibilityElement(children: .combine)
    }

    // MARK: model not ready

    private func modelCard(name: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                targetLabel
                Spacer()
                dismissButton
            }
            .frame(height: 26)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text("Your model is still downloading").font(.system(size: 14, weight: .semibold))
                ProgressBar(value: progress)
                Text("\(name) · \(Int(progress * 100))%").font(.mmCallout).monospacedDigit().foregroundStyle(Tokens.labelTertiary)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
            HStack(spacing: 8) {
                Spacer()
                Button("Wait") { controller.dismissError() }.buttonStyle(MurmurButtonStyle(height: 30, fontSize: 12.5))
                Button("Choose Another Model") {
                    controller.dismissError()
                    actions.openSettings(.voiceEngine)
                }
                .buttonStyle(MurmurButtonStyle(kind: .primary, height: 30, fontSize: 12.5))
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        }
        .frame(width: 400)
        .glassSurface(cornerRadius: Tokens.Radius.overlay)
    }

    // MARK: pieces

    private var modeMenu: some View {
        GlassMenuButton(keyboard: false, endsWithTake: true, items: { modeItems }) { isOpen in
            HStack(spacing: 4) {
                Text(settings.mode.label).font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(Tokens.accentText)
            .padding(EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 9))
            .frame(height: 26).chipPill()
            .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Pill()))
            .contentShape(Pill())
        }
        .fixedSize()
        .accessibilityLabel("Mode, \(settings.mode.label)")
    }

    private var modeItems: [GlassMenuItem] {
        var items = DictationMode.offered.map { mode in
            GlassMenuItem(title: mode.label, detail: mode.summary, symbol: mode.symbol, isSelected: settings.mode == mode) { settings.mode = mode }
        }
        if settings.cleanupEnabled {
            items += [.separator, .custom(CleanupStylePicker(settings: settings))]
        }
        return items
    }

    private var moreMenu: some View {
        GlassMenuButton(keyboard: false, endsWithTake: true, items: {
            [
                GlassMenuItem(title: "Insert now", keys: settings.hotkeyBindings.returnCommits || controller.isLatched ? "↩" : nil) { controller.stopAndInsert() },
                GlassMenuItem(title: "Open Settings…") { actions.openSettings(nil) },
                .separator,
                GlassMenuItem(title: "Cancel take", keys: "esc", isDestructive: true) { controller.cancel() },
            ]
        }) { isOpen in
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                .frame(width: 26, height: 26).chipPill()
                .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Pill()))
                .contentShape(Circle())
        }
        .fixedSize()
        .accessibilityLabel("More actions")
    }

    private var dismissButton: some View {
        Button {
            controller.dismissError()
        } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.labelSecondary)
                .frame(width: 26, height: 26).chipPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private var targetLabel: some View {
        HStack(spacing: 7) {
            if let icon = controller.target?.bundleIdentifier.flatMap(AppIcons.icon(forBundleIdentifier:)) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "text.cursor").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelSecondary).frame(width: 18, height: 18)
            }
            Text(controller.target?.name ?? "Front app").font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
        }
    }

    private func hintKey(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Tokens.labelSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .chipSurface(cornerRadius: 6)
    }
}

/// The foot of the overlay's mode menu: the cleanup style, changed without leaving the take.
private struct CleanupStylePicker: View {
    let settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            Text("Style").font(.system(size: 12)).foregroundStyle(Tokens.labelSecondary)
            SegmentedPicker(
                options: [CleanupPreset.lightTouch, .polished, .notes].map { ($0, $0.name) },
                selection: bind(settings, \.cleanupPreset), height: 22)
                .frame(width: 230)
        }
    }
}

/// An accent band sweeping across while the transcript is on its way. Still under Reduce Motion.
private struct Sweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4).fill(Tokens.control)
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [.clear, Tokens.accentSoft, Tokens.accent.opacity(0.35), Tokens.accentSoft, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: reduceMotion ? geo.size.width * 0.35 : (moving ? geo.size.width : -geo.size.width * 0.3))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: 6)
                .frame(maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { moving = true }
        }
        .accessibilityHidden(true)
    }
}

enum AppIcons {
    static func icon(forBundleIdentifier id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
