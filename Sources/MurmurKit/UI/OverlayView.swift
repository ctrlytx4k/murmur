import AppKit
import SwiftUI

/// The glass card that follows a take: listening, transcribing, inserted, or what went wrong.
/// It shows where the text is going and never takes focus.
struct OverlayView: View {
    let controller: DictationController
    let settings: SettingsStore

    var body: some View {
        Group {
            switch controller.state {
            case .recording(let since): listening(since: since)
            case .processing: processing
            case .inserted(let summary): inserted(summary)
            case .error(let error): errorCard(error)
            case .idle: EmptyView()
            }
        }
        .foregroundStyle(Tokens.label)
    }

    // MARK: listening

    private func listening(since: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                targetLabel
                Spacer()
            }
            .frame(height: 26)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 10))

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
                Text("Listening…")
                    .font(.mmTranscript).foregroundStyle(Tokens.labelSecondary)
                    .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
            }

            HStack(spacing: 10) {
                PulseDot(pulsing: !controller.isSilent)
                Waveform(levels: controller.levels, color: controller.isSilent ? Tokens.warning : Tokens.label)
                ElapsedTime(since: since).font(.mmMono).foregroundStyle(Tokens.labelTertiary)
                HStack(spacing: 4) {
                    hintKey("esc")
                    if settings.behavior == .toggle { hintKey("↩") }
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
                Text("Transcribing…").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
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

    // MARK: pieces

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
