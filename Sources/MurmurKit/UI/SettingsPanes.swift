import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Voice Engine

struct VoiceEnginePane: View {
    let stores: Stores
    private var settings: SettingsStore { stores.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(title: "Speech model") {
                ForEach(Array(stores.catalog.models.enumerated()), id: \.element.id) { index, model in
                    modelRow(model, first: index == 0)
                }
            }
            if let error = stores.catalog.downloadError {
                Text(error).font(.mmSub).foregroundStyle(Tokens.warning).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
            Text("Speed and accuracy are relative to each other on this Mac.")
                .font(.mmSub).foregroundStyle(Tokens.labelTertiary).padding(.horizontal, 4)
        }

        SettingsGroup(title: "Processing") {
            SettingsRow(title: "Language", subtitle: "The language you dictate in", showsDivider: false) {
                GlassPopUpButton(label: "Language", options: SettingsStore.languages.map { ($0, $0) }, selection: bind(settings, \.language))
            }
            SettingsRow(title: "Model storage", subtitle: "~/Library/Application Support/Murmur/Models") {
                Button("Show in Finder") {
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let models = support.appendingPathComponent("Murmur/Models")
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: models.path) ? models : support])
                }
                .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
        }
    }

    private func modelRow(_ model: SpeechModel, first: Bool) -> some View {
        let active = settings.modelID == model.id && model.isUsable
        return HStack(spacing: 12) {
            Circle()
                .fill(active ? Tokens.accent : Tokens.elevated)
                .overlay(Circle().strokeBorder(active ? .clear : Tokens.stroke, lineWidth: 1.5))
                .overlay { if active { Circle().fill(Tokens.onAccent).frame(width: 6, height: 6) } }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).fixedSize()
                    if model.usesNeuralEngine {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu").font(.system(size: 9, weight: .bold))
                            Text("Neural Engine").font(.system(size: 10.5, weight: .bold))
                        }
                        .foregroundStyle(Tokens.accentText)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Tokens.accentSoft, in: Pill())
                        .fixedSize()
                    }
                }
                Text(model.detail).font(.mmSub).foregroundStyle(Tokens.labelTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { Text("Speed"); MeterDots(filled: model.speed) }
                GridRow { Text("Accuracy"); MeterDots(filled: model.accuracy) }
            }
            .font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
            .frame(width: 128, alignment: .leading)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch model.status {
                case .builtIn, .installed:
                    if active {
                        Text("In use").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.accentText)
                    } else {
                        Button("Use") { settings.modelID = model.id }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                    }
                case .available:
                    Button { stores.catalog.requestDownload(model.id) } label: { Label("Download", systemImage: "arrow.down.to.line") }
                        .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressBar(value: progress, height: 5)
                        Text("\(Int(progress * 100))%").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Tokens.labelTertiary)
                    }
                    if !stores.catalog.downloadsAreReal {
                        IconButton(symbol: "xmark", label: "Cancel download", tint: Tokens.label, chip: true) { stores.catalog.cancelDownload(model.id) }
                    }
                case .unavailable(let why):
                    Text(why).font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary).multilineTextAlignment(.trailing)
                }
            }
            .frame(width: 130)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 68)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Tokens.separator).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}

// MARK: AI Cleanup

struct CleanupPane: View {
    let stores: Stores
    private var settings: SettingsStore { stores.settings }
    private let presetOptions: [(String, String)] = [("raw", "Raw")] + CleanupPreset.allCases.map { ($0.rawValue, $0.name) }

    var body: some View {
        SettingsGroup {
            SwitchRow(
                title: "Clean up text after transcription",
                subtitle: "Fixes punctuation and casing, drops filler words. Used by Cleaned up mode.",
                first: true, isOn: bind(settings, \.cleanupEnabled))
            switch stores.controller.cleanupAvailability {
            case .available(let model):
                SettingsRow(title: model, subtitle: stores.isDemo ? "Simulated · drops filler words only" : "Built into macOS · runs on this Mac, nothing is sent anywhere") {
                    Text("Ready").font(.mmSub).fontWeight(.semibold).foregroundStyle(Tokens.success)
                }
            case .unavailable(let reason):
                SettingsRow(title: reason, subtitle: "Until it is available, Cleaned up mode inserts the text as spoken") {
                    Text("Unavailable").font(.mmSub).fontWeight(.semibold).foregroundStyle(Tokens.warning)
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Default preset").font(.mmBodyEmphasis).padding(.leading, 4)
            HStack(spacing: 8) {
                ForEach(CleanupPreset.allCases, id: \.self) { preset in
                    let on = settings.cleanupPreset == preset
                    Button {
                        settings.cleanupPreset = preset
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.label)
                            Text(preset.summary).font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary).multilineTextAlignment(.leading)
                        }
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .background(on ? Tokens.accentSoft : Tokens.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Tokens.accentText : Tokens.stroke, lineWidth: on ? 1.5 : 0.5))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            let custom = settings.cleanupPreset == .custom
            Text(custom ? "Instructions for “Custom”" : "Instructions for “\(settings.cleanupPreset.name)” · built-in presets are read-only; choose Custom to write your own")
                .font(.mmSub).foregroundStyle(Tokens.labelTertiary).padding(.top, 2)
            Group {
                if custom {
                    TextEditor(text: bind(settings, \.customInstructions)).scrollContentBackground(.hidden)
                } else {
                    Text(settings.cleanupPreset.builtInInstructions).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).textSelection(.enabled)
                }
            }
            .font(.system(size: 12, design: .monospaced)).lineSpacing(3).foregroundStyle(Tokens.labelSecondary)
            .padding(EdgeInsets(top: 10, leading: custom ? 8 : 12, bottom: 10, trailing: 12))
            .frame(height: 72)
            .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(custom ? Tokens.accentText : Tokens.stroke, lineWidth: custom ? 1.5 : 0.5))
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-app behavior").font(.mmBodyEmphasis).padding(.leading, 4)
                Spacer()
                Button { addApp() } label: { Label("Add App…", systemImage: "plus") }
                    .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
            SettingsGroup {
                ForEach(Array(settings.appPresets.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 12) {
                        AppBadge(name: app.name, bundleIdentifier: app.bundleIdentifier, size: 24)
                        Text(app.name).font(.mmBody)
                        Spacer()
                        if app.preset == "raw" { Text("no cleanup").font(.mmSub).foregroundStyle(Tokens.labelTertiary) }
                        GlassPopUpButton(
                            label: "Preset for \(app.name)", options: presetOptions,
                            selection: Binding(get: { app.preset }, set: { settings.appPresets[index].preset = $0 }))
                        IconButton(symbol: "minus.circle", label: "Remove \(app.name)") { settings.appPresets.removeAll { $0.id == app.id } }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 42)
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Tokens.separator).frame(height: 1) } }
                }
                Text(settings.appPresets.isEmpty ? "No per-app rules yet. Every app uses the default preset." : "All other apps use the default preset.")
                    .font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .padding(.horizontal, 14)
                    .overlay(alignment: .top) { if !settings.appPresets.isEmpty { Rectangle().fill(Tokens.separator).frame(height: 1) } }
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        guard !settings.appPresets.contains(where: { $0.bundleIdentifier == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        settings.appPresets.append(AppPreset(bundleIdentifier: id, name: name, preset: CleanupPreset.lightTouch.rawValue))
    }
}

// MARK: Privacy

struct PrivacyPane: View {
    let stores: Stores
    private var settings: SettingsStore { stores.settings }
    @State private var confirmingClear = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "lock").font(.system(size: 19, weight: .medium)).foregroundStyle(Tokens.onAccent)
                .frame(width: 44, height: 44)
                .background(Tokens.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing you say leaves your Mac.").font(.system(size: 19, weight: .bold)).kerning(-0.2)
                Text("Audio is transcribed on this Mac and discarded once the text is ready. No account, no analytics, no crash uploads. The only network use is model downloads and update checks, and you can switch both off.")
                    .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))

        SettingsGroup(title: "Network") {
            SwitchRow(title: "Offline mode", subtitle: "Blocks model and language downloads. Dictation itself never uses the network.", first: true, isOn: bind(settings, \.offlineMode))
            SwitchRow(title: "Log network activity", subtitle: "Keeps a local record of every download Murmur starts", isOn: bind(settings, \.logsNetworkActivity))
            logRow(["When", "Host", "Why", "Size"]).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(Tokens.labelTertiary)
                .frame(height: 26).background(Tokens.control)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
            ForEach(stores.network.entries.prefix(5)) { entry in
                logRow([
                    entry.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()), entry.host, entry.reason,
                    ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file),
                ])
                .font(.mmCallout).foregroundStyle(Tokens.labelSecondary).frame(minHeight: 30)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
            }
            HStack {
                Text(stores.network.entries.isEmpty ? "No requests recorded · audio and text sent: 0 bytes" : "\(stores.network.entries.count) requests recorded · audio and text sent: 0 bytes")
                    .font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
                Spacer()
                Button("Clear") { stores.network.clear() }.buttonStyle(MurmurButtonStyle(height: 26, fontSize: 12)).disabled(stores.network.entries.isEmpty)
            }
            .padding(.horizontal, 14).frame(minHeight: 38)
            .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
        }

        SettingsGroup(title: "History on this Mac") {
            SettingsRow(title: "Keep transcriptions", subtitle: "Stored in your Library folder, never synced", showsDivider: false) {
                GlassPopUpButton("Keep transcriptions", selection: Binding(get: { settings.retention }, set: { new in
                    settings.retention = new
                    stores.history.prune(retention: new)
                }))
                Button("Clear History…") { confirmingClear = true }
                    .buttonStyle(MurmurButtonStyle(kind: .danger, height: 28, fontSize: 12.5))
                    .disabled(stores.history.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { stores.history.clear() }
        } message: {
            Text("This removes \(stores.history.entries.count) transcriptions from this Mac. It can’t be undone.")
        }
    }

    private func logRow(_ cells: [String]) -> some View {
        HStack(spacing: 10) {
            Text(cells[0]).monospacedDigit().frame(width: 96, alignment: .leading)
            Text(cells[1]).frame(width: 130, alignment: .leading)
            Text(cells[2]).frame(maxWidth: .infinity, alignment: .leading)
            Text(cells[3]).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
    }
}

// MARK: Advanced

struct AdvancedPane: View {
    let stores: Stores
    private var settings: SettingsStore { stores.settings }
    @Environment(\.appActions) private var actions
    @State private var confirmingReset = false

    var body: some View {
        SettingsGroup(title: "Text insertion") {
            SettingsRow(title: "Insert by", subtitle: "Pasting is faster for long text; typing works in more apps", showsDivider: false) {
                GlassPopUpButton("Insert by", selection: bind(settings, \.insertMethod))
            }
            SwitchRow(title: "Restore clipboard after pasting", isOn: bind(settings, \.restoresClipboard))
            SwitchRow(title: "Add a space after inserted text", isOn: bind(settings, \.addsTrailingSpace))
        }

        SettingsGroup(title: "Audio") {
            SettingsRow(title: "Maximum recording length", subtitle: "Recording stops and inserts when reached", showsDivider: false) {
                GlassPopUpButton("Maximum recording length", selection: bind(settings, \.maxLength))
            }
        }

        SettingsGroup(title: "Troubleshooting") {
            SwitchRow(title: "Debug log", subtitle: "Timing and errors only, never audio or text", first: true, isOn: bind(settings, \.debugLog))
            SettingsRow(title: "Onboarding", subtitle: "Walk through the welcome and permission steps again") {
                Button("Show Again") { actions.openOnboarding(nil) }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
            SettingsRow(title: "Acknowledgements", subtitle: "The open-source speech engine and model Murmur is built on") {
                Button("Show") { actions.showAcknowledgements() }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
            SettingsRow(title: "Diagnostics", subtitle: "Saves a file you can attach to a bug report. Nothing is sent automatically.") {
                Button("Export…") { exportDiagnostics() }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                Button("Reset All Settings…") { confirmingReset = true }.buttonStyle(MurmurButtonStyle(kind: .danger, height: 28, fontSize: 12.5))
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset All Settings", role: .destructive) { settings.resetAll() }
        } message: {
            Text("Shortcuts, appearance and every other setting go back to their defaults. History, dictionary and snippets are kept.")
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Murmur diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var report = settings.diagnostics()
        report["permissions"] = stores.controller.permissions.missing.isEmpty ? "all granted" : "missing: " + stores.controller.permissions.missing.map(\.name).joined(separator: ", ")
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: url)
    }
}
