import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, tryIt

    var permission: Permission? {
        switch self {
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        default: nil
        }
    }

    static func step(for permission: Permission) -> OnboardingStep {
        switch permission {
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        }
    }
}

/// First launch: the privacy promise, three permissions checked live, then a practice field. 620 x 540.
struct OnboardingView: View {
    let controller: DictationController
    let settings: SettingsStore
    @State var step: OnboardingStep = .welcome
    var onFinish: () -> Void = {}

    @State private var meter = MicLevelMonitor()
    @State private var practice = ""
    @FocusState private var practiceFocused: Bool
    /// Permissions can change in System Settings at any moment, so poll while this window is open.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var granted: Bool { step.permission.map(controller.permissions.isGranted) ?? true }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40)
            Group {
                switch step {
                case .welcome: welcome
                case .tryIt: tryIt
                default: permissionStep(step.permission!)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 52, bottom: 0, trailing: 52))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 620, height: 540)
        .background(Tokens.windowBackground)
        .foregroundStyle(Tokens.label)
        .onReceive(poll) { _ in controller.refreshPermissions() }
        .onChange(of: step, initial: true) { _, new in
            settings.onboardingStep = new.rawValue
            if new == .microphone { meter.start() } else { meter.stop() }
        }
        .onChange(of: controller.permissions.microphone) { _, isOn in
            if isOn, step == .microphone { meter.start() }
        }
        .onChange(of: controller.permissions) { old, new in
            // A permission step that just turned green moves on by itself after a beat. The microphone
            // step stays, so the level meter can be seen moving.
            guard let permission = step.permission, permission != .microphone, !old.isGranted(permission), new.isGranted(permission) else { return }
            let current = step
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if step == current { advance() }
            }
        }
        .onDisappear { meter.stop() }
    }

    // MARK: welcome

    private var welcome: some View {
        VStack(spacing: 14) {
            AppIconTile(size: 92).padding(.top, 10)
            Text("Dictation that stays\non your Mac.")
                .font(.mmDisplay).kerning(-0.4).multilineTextAlignment(.center).lineSpacing(2).padding(.top, 4)
            Text("Hold a key, speak, and Murmur types what you said into whatever app you’re using.")
                .font(.system(size: 13.5)).lineSpacing(4).foregroundStyle(Tokens.labelSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            VStack(alignment: .leading, spacing: 10) {
                promise("cpu", "Transcribed on this Mac.", "Audio never leaves it.")
                promise("lock", "No account, no tracking.", "Nothing to sign up for.")
                HStack(spacing: 12) {
                    Image(systemName: "curlybraces").font(.system(size: 14)).foregroundStyle(Tokens.accentText).frame(width: 18)
                    Text("Free and open source.").fontWeight(.semibold)
                    if let url = AppInfo.repository {
                        Link("Read the code", destination: url).foregroundStyle(Tokens.accentText)
                    } else {
                        Text("MIT licensed.").foregroundStyle(Tokens.labelSecondary)
                    }
                }
                .font(.mmBody)
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
            .padding(.top, 4)
        }
    }

    private func promise(_ symbol: String, _ bold: String, _ rest: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Tokens.accentText).frame(width: 18)
            (Text(bold).fontWeight(.semibold) + Text(" \(rest)").foregroundStyle(Tokens.labelSecondary)).font(.mmBody)
        }
    }

    // MARK: permissions

    private struct Copy {
        var symbol: String, step: String, title: String, why: String, never: String, okTitle: String, okSub: String, path: String
    }

    private func copy(for permission: Permission) -> Copy {
        switch permission {
        case .microphone:
            Copy(symbol: "mic", step: "Step 2 of 4 · Microphone", title: "Let Murmur hear you",
                 why: "Murmur listens only while you hold or toggle your shortcut. The microphone indicator in your menu bar shows whenever it is on.",
                 never: "Never: background listening, wake words, or saving audio.",
                 okTitle: "Microphone access granted", okSub: "Say something; the meter should move.", path: "Microphone")
        case .accessibility:
            Copy(symbol: "accessibility", step: "Step 3 of 4 · Accessibility", title: "Let Murmur type for you",
                 why: "Accessibility lets Murmur place text at your cursor in any app, the same way a keyboard would.",
                 never: "Never: reading other windows, clicking for you, or typing into password fields.",
                 okTitle: "Accessibility granted", okSub: "Murmur can type into the app you’re using.", path: "Accessibility")
        case .inputMonitoring:
            Copy(symbol: "keyboard", step: "Step 4 of 4 · Input Monitoring", title: "Let your shortcut work everywhere",
                 why: "Input Monitoring lets Murmur notice your dictation shortcut even when another app is in front.",
                 never: "Never: logging keystrokes. Murmur only watches for the one shortcut you set.",
                 okTitle: "Input Monitoring granted", okSub: "Your shortcut is \(settings.shortcut.spokenName). Change it any time in Settings.", path: "Input Monitoring")
        }
    }

    private func permissionStep(_ permission: Permission) -> some View {
        let c = copy(for: permission)
        return VStack(alignment: .leading, spacing: 12) {
            Image(systemName: c.symbol).font(.system(size: 22)).foregroundStyle(Tokens.accentText)
                .frame(width: 54, height: 54).chipSurface(cornerRadius: 16)
            Text(c.step).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.labelTertiary)
            Text(c.title).font(.system(size: 24, weight: .bold)).kerning(-0.2)
            Text(c.why).font(.system(size: 13.5)).lineSpacing(4).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
            Text(c.never).font(.mmCallout).lineSpacing(2).foregroundStyle(Tokens.labelTertiary).fixedSize(horizontal: false, vertical: true)

            if controller.permissions.isGranted(permission) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Tokens.success, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.okTitle).font(.system(size: 13.5, weight: .semibold))
                        Text(c.okSub).font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
                    }
                    Spacer(minLength: 0)
                    if permission == .microphone { meterBars }
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .background(Tokens.successSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.success.opacity(0.28), lineWidth: 1))
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Spinner(size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Waiting for permission…").font(.system(size: 13.5, weight: .semibold))
                            Text("This turns green on its own.").font(.mmCallout).foregroundStyle(Tokens.labelSecondary)
                        }
                        Spacer(minLength: 0)
                        Button(permission == .microphone ? "Allow Microphone" : "Open System Settings") { controller.request(permission) }
                            .buttonStyle(MurmurButtonStyle(kind: .primary, height: 32))
                    }
                    HStack(spacing: 6) {
                        Text("Privacy & Security")
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        Text(c.path)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        Text("turn on ") + Text("Murmur").fontWeight(.semibold).foregroundStyle(Tokens.labelSecondary)
                    }
                    .font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                    if permission != .microphone {
                        // macOS ties these grants to the exact build. After a rebuild the switch still looks on but no longer counts.
                        Text("Already switched on? Select Murmur in that list, remove it with −, then add it again with +.")
                            .font(.mmSub).foregroundStyle(Tokens.labelTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                .padding(.top, 6)
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meterBars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(meter.levels.enumerated()), id: \.offset) { _, level in
                Pill().fill(Tokens.success).frame(width: 2, height: max(3, CGFloat(level) * 22))
            }
        }
        .frame(height: 22)
        .accessibilityLabel("Input level")
    }

    // MARK: try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.permissions.allGranted ? "All set · permissions granted" : "Almost there · some permissions are still off")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(controller.permissions.allGranted ? Tokens.success : Tokens.warning)
            Text("Try it now").font(.system(size: 24, weight: .bold)).kerning(-0.2)
            HStack(spacing: 5) {
                let tap = settings.shortcut.isDoubleTap
                let hold = !tap && settings.behavior == .pushToTalk
                Text(tap ? "Click the field, tap" : (hold ? "Click the field, hold" : "Click the field, press"))
                ForEach(settings.shortcut.keycaps, id: \.self) { Keycap(text: $0) }
                Text(tap ? ", say a sentence, then tap it twice again." : (hold ? "and say a sentence, then let go." : "and say a sentence, then press it again."))
            }
            .font(.system(size: 13.5)).foregroundStyle(Tokens.labelSecondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Practice field").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                TextEditor(text: $practice)
                    .font(.system(size: 14)).lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($practiceFocused)
                    .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    .frame(height: 108)
                    .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tokens.accentText, lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) {
                        if case .inserted = controller.state {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                Text("Inserted").font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Tokens.success)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Tokens.successSoft, in: Pill())
                            .padding(10)
                        }
                    }
                    .accessibilityLabel("Practice field")
            }
            Text("You can change the shortcut, or switch between push-to-talk and toggle, any time in Settings.")
                .font(.mmCallout).lineSpacing(2).foregroundStyle(Tokens.labelTertiary)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { practiceFocused = true }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                let current = min(max(step.rawValue + 1, 1), 4)
                ForEach(1...4, id: \.self) { i in
                    Pill().fill(i <= current ? Tokens.accent : Tokens.controlStrong).frame(width: i == current ? 20 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(step == .tryIt ? "All steps complete" : "Step \(step.rawValue + 1) of 4")
            Spacer()
            if step.permission != nil, !granted {
                Button("Skip for now") { advance() }.buttonStyle(LinkButtonStyle(color: Tokens.labelSecondary)).padding(.horizontal, 10)
            }
            if step != .welcome {
                Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(MurmurButtonStyle(height: 32))
            }
            Button(step == .welcome ? "Get Started" : (step == .tryIt ? "Done" : "Continue")) { advance() }
                .buttonStyle(MurmurButtonStyle(kind: .primary, height: 32))
                .disabled(!granted)
                .keyboardShortcut(.defaultAction)
        }
        .padding(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 22))
        .frame(height: 66)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
    }

    private func advance() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            step = next
        } else {
            settings.hasCompletedOnboarding = true
            settings.onboardingStep = 0
            onFinish()
        }
    }
}
