import AppKit
import SwiftUI

// MARK: small pieces

/// Says where text is handled. Green for this Mac; amber whenever text leaves it.
struct PlaceBadge: View {
    let isLocal: Bool
    var cloudText = "Cloud · sends text"
    var height: CGFloat = 20

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isLocal ? "desktopcomputer" : "cloud").font(.system(size: height * 0.45, weight: .bold))
            Text(isLocal ? "On this Mac" : cloudText).font(.system(size: height * 0.525, weight: .bold))
        }
        .foregroundStyle(isLocal ? Tokens.success : Tokens.warning)
        .padding(.horizontal, height * 0.4).frame(height: height)
        .background(isLocal ? Tokens.successSoft : Tokens.warningSoft, in: Pill())
        .fixedSize()
    }
}

/// A neutral letter tile for a provider. Never a company logo.
struct ProviderTile: View {
    let kind: ProviderKind
    var size: CGFloat = 30

    var body: some View {
        Group {
            if kind == .appleIntelligence {
                Image(systemName: "sparkles").font(.system(size: size * 0.43, weight: .semibold))
            } else {
                Text(kind.letter).font(.system(size: size * 0.43, weight: .bold))
            }
        }
        .foregroundStyle(Tokens.labelSecondary)
        .frame(width: size, height: size)
        .background(Tokens.controlStrong, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct RadioMark: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Tokens.accent : Tokens.elevated)
            .overlay { if on { Circle().fill(Tokens.onAccent).frame(width: 6, height: 6) } else { Circle().strokeBorder(Tokens.stroke, lineWidth: 1.5) } }
            .frame(width: 18, height: 18)
    }
}

enum ProviderSheet: Identifiable {
    case add
    case setup(ProviderConfig, isNew: Bool)
    case consent(ProviderConfig)

    var id: String {
        switch self {
        case .add: "add"
        case .setup(let provider, _): "setup-\(provider.id)"
        case .consent(let provider): "consent-\(provider.id)"
        }
    }
}

// MARK: the Provider section of Settings › AI Cleanup

struct ProviderSection: View {
    let stores: Stores
    /// What the last look at each provider found, by id: "Running", "Works · 0.7 s", "Not reachable".
    @State var status: [String: String] = [:]
    @State private var sheet: ProviderSheet?

    private var providers: ProviderStore { stores.providers }
    private var router: CleanupRouter { stores.controller.cleanupRouter }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Provider").font(.mmBodyEmphasis).padding(.leading, 4)
                Spacer()
                Button { sheet = .add } label: { Label("Add Provider…", systemImage: "plus") }
                    .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            }
            SettingsGroup {
                ForEach(Array(providers.all.enumerated()), id: \.element.id) { index, provider in
                    row(provider, first: index == 0)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cleanup provider")
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("Only text is sent, never audio: transcription always runs on this Mac. Each request appears in Privacy › Network log.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.mmSub).foregroundStyle(Tokens.labelTertiary).padding(.horizontal, 4)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                AddProviderSheet(router: router, onCancel: { self.sheet = nil }) { provider in self.sheet = .setup(provider, isNew: true) }
            case .setup(let provider, let isNew):
                ProviderSetupSheet(stores: stores, provider: provider, isNew: isNew, onCancel: { self.sheet = nil }) { saved, key in
                    providers.save(saved, key: key)
                    self.sheet = nil
                    // A new provider is what the user came for: choose it, asking first if it is a cloud one.
                    if isNew { choose(saved) }
                }
            case .consent(let provider):
                ProviderConsentSheet(provider: provider, onDecline: { self.sheet = nil }) {
                    providers.grantConsentAndSelect(provider.id)
                    self.sheet = nil
                }
            }
        }
        // Servers on this Mac are asked once, when the pane opens. Cloud providers are never contacted from here.
        .task { await checkLocalServers() }
    }

    private func choose(_ provider: ProviderConfig) {
        if !providers.select(provider.id) {
            // Give a sheet that is closing time to go before the next one opens.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                sheet = .consent(provider)
            }
        }
    }

    private func checkLocalServers() async {
        for provider in providers.added where provider.isLocal && status[provider.id] == nil {
            status[provider.id] = await router.isRunning(provider) ? "Running" : "Not running"
        }
    }

    private func statusLine(_ provider: ProviderConfig) -> (text: String, color: Color) {
        if provider.kind == .appleIntelligence {
            let ready = stores.controller.localCleanupAvailability.isAvailable
            if providers.selectedID == provider.id, ready { return ("In use", Tokens.accentText) }
            return ready ? ("Ready", Tokens.success) : ("Unavailable", Tokens.warning)
        }
        if let known = status[provider.id], known != "Running" || providers.selectedID != provider.id {
            let good = known == "Running" || known.hasPrefix("Works")
            return (known, good ? Tokens.success : known == "Testing…" ? Tokens.labelTertiary : Tokens.warning)
        }
        return providers.selectedID == provider.id ? ("In use", Tokens.accentText) : ("", Tokens.labelTertiary)
    }

    private func detail(_ provider: ProviderConfig) -> String {
        switch provider.kind {
        case .appleIntelligence:
            if case .unavailable(let reason) = stores.controller.localCleanupAvailability { return reason }
            return stores.isDemo ? "Simulated · drops filler words only" : "Built into macOS"
        case .localServer: return "\(provider.hostLabel) · \(provider.model)"
        case .anthropic, .openAI: return "\(provider.kind.label) · \(provider.model) · key in Keychain"
        case .openAICompatible: return "OpenAI-compatible · \(provider.hostLabel) · \(provider.model)"
        }
    }

    private func row(_ provider: ProviderConfig, first: Bool) -> some View {
        let on = providers.selectedID == provider.id
        let state = statusLine(provider)
        return HStack(spacing: 12) {
            Button { choose(provider) } label: {
                HStack(spacing: 12) {
                    RadioMark(on: on)
                    ProviderTile(kind: provider.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(provider.name).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                            PlaceBadge(isLocal: provider.isLocal)
                        }
                        Text(detail(provider)).font(.mmSub).foregroundStyle(Tokens.labelTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(state.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(state.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.name), \(provider.isLocal ? "on this Mac" : "cloud, sends text"), \(state.text)")
            .accessibilityAddTraits(on ? .isSelected : [])

            if provider.kind == .appleIntelligence {
                // Built in: nothing to edit, test or remove.
                Color.clear.frame(width: 26, height: 26)
            } else {
                GlassMenuButton(items: {
                    [
                        GlassMenuItem(title: "Edit…") { sheet = .setup(provider, isNew: false) },
                        GlassMenuItem(title: "Test") { test(provider) },
                        .separator,
                        GlassMenuItem(title: "Remove", isDestructive: true) {
                            providers.remove(provider.id)
                            status[provider.id] = nil
                        },
                    ]
                }) { isOpen in
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(Tokens.labelTertiary)
                        .frame(width: 26, height: 26)
                        .modifier(GlassMenuOpenHighlight(isOpen: isOpen, shape: Circle()))
                        .contentShape(Circle())
                }
                .accessibilityLabel("\(provider.name) options")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Tokens.separator).frame(height: 1) } }
    }

    private func test(_ provider: ProviderConfig) {
        status[provider.id] = "Testing…"
        Task {
            do {
                let result = try await router.test(provider, key: nil)
                providers.save(result.provider, key: nil)
                status[provider.id] = "Works · \(String(format: "%.1f", result.seconds)) s"
            } catch {
                let failure = error as? ProviderError ?? .unreachable
                status[provider.id] = failure == .unreachable || failure == .timeout ? "Not reachable" : failure.summary
            }
        }
    }
}

/// The rules that apply once a cloud provider exists. Hidden until one does: there is nothing for them to do.
struct CloudRulesGroup: View {
    let stores: Stores
    private var providers: ProviderStore { stores.providers }

    var body: some View {
        SettingsGroup(title: "When a cloud provider is in use") {
            SettingsRow(title: "If it fails or you’re offline", subtitle: "Offline mode always uses this", showsDivider: false) {
                GlassPopUpButton(label: "If it fails or you’re offline", options: ProviderStore.Fallback.allCases.map { ($0, $0.rawValue) }, selection: bind(providers, \.fallback))
            }
            SettingsRow(title: "Keep these apps on this Mac", subtitle: "Takes in these apps never go to the cloud") {
                HStack(spacing: 6) {
                    ForEach(providers.stayLocalApps) { app in
                        HStack(spacing: 6) {
                            AppBadge(name: app.name, bundleIdentifier: app.bundleIdentifier, size: 18)
                            Text(app.name).font(.system(size: 12)).lineLimit(1)
                            Button { providers.stayLocalApps.removeAll { $0.id == app.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.labelTertiary)
                            }
                            .buttonStyle(.plain).accessibilityLabel("Stop keeping \(app.name) on this Mac")
                        }
                        .padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 9)).frame(height: 26).chipPill()
                    }
                    Button { addApp() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(MurmurButtonStyle(height: 26, fontSize: 12))
                        .accessibilityLabel("Add app")
                }
            }
            SettingsRow(title: "Show the provider on the overlay", subtitle: "The card says “via \(providers.added.first { $0.isCloud }?.name ?? "the provider")” on every cloud take") {
                Text("Always on").font(.mmCallout).foregroundStyle(Tokens.labelTertiary)
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        guard !providers.stayLocalApps.contains(where: { $0.bundleIdentifier == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        providers.stayLocalApps.append(StayLocalApp(bundleIdentifier: id, name: name))
    }
}

// MARK: sheets

private struct SheetFrame<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) { header }
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 6, trailing: 24))
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(EdgeInsets(top: 12, leading: 24, bottom: 18, trailing: 24))
            HStack(spacing: 8) { footer }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
        }
        .frame(width: 440)
        .background(Tokens.elevated)
        .foregroundStyle(Tokens.label)
    }
}

/// Sheet B: what kind of provider to add.
struct AddProviderSheet: View {
    let router: CleanupRouter
    var onCancel: () -> Void = {}
    var onPick: (ProviderConfig) -> Void = { _ in }
    /// Servers found on this Mac. Looked for once, when the sheet opens.
    @State var found: [ProviderConfig] = []

    var body: some View {
        SheetFrame {
            Text("Add a provider").font(.system(size: 17, weight: .bold))
            Text("Used for Cleaned up mode. Transcription never changes: it stays on this Mac.").font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary)
        } content: {
            groupLabel("On this Mac", isLocal: true)
            tile(.localServer, "Ollama, LM Studio, llama.cpp.", found: found.first.map { "Found \($0.name) on port \($0.url?.port ?? 0)" }) {
                onPick(found.first.map { ProviderConfig(kind: .localServer, name: $0.name, baseURL: $0.baseURL) } ?? ProviderConfig(kind: .localServer))
            }
            groupLabel("Cloud", isLocal: false).padding(.top, 6)
            tile(.anthropic, "Claude models, with your API key") { onPick(ProviderConfig(kind: .anthropic)) }
            tile(.openAI, "GPT models, with your API key") { onPick(ProviderConfig(kind: .openAI)) }
            tile(.openAICompatible, "OpenRouter, Groq, Together, or your own server") { onPick(ProviderConfig(kind: .openAICompatible)) }
        } footer: {
            Button("Cancel", action: onCancel).buttonStyle(MurmurButtonStyle(height: 32)).keyboardShortcut(.cancelAction)
        }
        .task { if found.isEmpty { found = await router.findLocalServers().map(\.provider) } }
    }

    private func groupLabel(_ text: String, isLocal: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text.uppercased()).font(.system(size: 12, weight: .bold)).kerning(0.5).foregroundStyle(Tokens.labelSecondary)
            PlaceBadge(isLocal: isLocal)
        }
    }

    private func tile(_ kind: ProviderKind, _ detail: String, found: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderTile(kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label).font(.system(size: 13, weight: .semibold))
                    Group {
                        if let found {
                            Text("\(detail) \(Text(found).fontWeight(.semibold).foregroundStyle(Tokens.success))")
                        } else {
                            Text(detail)
                        }
                    }
                    .font(.mmSub).foregroundStyle(Tokens.labelTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.labelTertiary)
            }
            .padding(12)
            .background(Tokens.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Sheet C: address, key and model, with a test that has to pass before the provider can be added.
struct ProviderSetupSheet: View {
    enum Phase: Equatable {
        case idle, working(String)
        /// The key checked out and the models are listed; the user has to pick one.
        case chooseModel
        case passed(CleanupRouter.TestResult)
        case failed(String)
    }

    let stores: Stores
    let isNew: Bool
    var onCancel: () -> Void = {}
    var onSave: (ProviderConfig, String?) -> Void = { _, _ in }

    @State private var provider: ProviderConfig
    @State private var key: String
    @State private var models: [ProviderAPI.Model]
    @State private var phase: Phase

    init(
        stores: Stores, provider: ProviderConfig, isNew: Bool, key: String = "", models: [ProviderAPI.Model] = [], phase: Phase = .idle,
        onCancel: @escaping () -> Void = {}, onSave: @escaping (ProviderConfig, String?) -> Void = { _, _ in }
    ) {
        self.stores = stores
        self.isNew = isNew
        self.onCancel = onCancel
        self.onSave = onSave
        _provider = State(initialValue: provider)
        _key = State(initialValue: key)
        _models = State(initialValue: models)
        _phase = State(initialValue: phase)
    }

    private var router: CleanupRouter { stores.controller.cleanupRouter }
    private var kind: ProviderKind { provider.kind }
    private var hasSavedKey: Bool { !isNew && stores.providers.keys.key(for: provider.id) != nil }
    /// The key to use: the one just typed, or the one already in the Keychain.
    private var workingKey: String? {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? stores.providers.keys.key(for: provider.id) : typed
    }
    private var isWorking: Bool { if case .working = phase { true } else { false } }
    private var passed: Bool { if case .passed = phase { true } else { false } }
    private var canTest: Bool {
        !isWorking && !provider.baseURL.trimmingCharacters(in: .whitespaces).isEmpty && (!kind.needsKey || workingKey?.isEmpty == false)
            && (models.isEmpty || !provider.model.isEmpty)
    }

    var body: some View {
        SheetFrame {
            HStack(spacing: 10) {
                ProviderTile(kind: kind)
                Text(kind.label).font(.system(size: 17, weight: .bold))
                PlaceBadge(isLocal: provider.isLocal)
            }
            Text(blurb).font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
        } content: {
            if kind.hasEditableAddress {
                field("Name") { TextField("Name", text: $provider.name).fieldChrome() }
                field("Address", note: provider.isLocal || provider.baseURL.isEmpty ? "The server’s OpenAI-compatible address, ending in /v1." : "This address is not on this Mac, so text sent to it leaves this Mac.") {
                    TextField(kind == .localServer ? "http://localhost:11434/v1" : "https://example.com/v1", text: $provider.baseURL).fieldChrome()
                        .onChange(of: provider.baseURL) { reset() }
                }
            }
            if kind.acceptsKey {
                field("API key", note: "Saved in your macOS Keychain, not in Murmur’s files.", link: kind.keyPage.map { ("Where do I get a key?", $0) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "key").font(.system(size: 12)).foregroundStyle(Tokens.labelSecondary)
                        SecureField(hasSavedKey ? "Saved in Keychain · leave empty to keep it" : (kind.needsKey ? "Paste your key" : "Optional"), text: $key)
                            .textFieldStyle(.plain).font(.mmBody)
                            .onChange(of: key) { reset() }
                        Button("Paste") { key = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? key }
                            .buttonStyle(.plain).font(.mmSub).foregroundStyle(Tokens.accentText)
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Tokens.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(key.isEmpty ? Tokens.stroke : Tokens.accentText, lineWidth: key.isEmpty ? 0.5 : 1.5))
                }
            }
            field("Model", note: models.isEmpty ? (kind.needsKey ? "Listed from your account after the key checks out." : "Listed from the server when you test.") : nil) {
                if models.isEmpty {
                    TextField("Found when you test", text: $provider.model).fieldChrome().font(.system(size: 12.5, design: .monospaced))
                        .onChange(of: provider.model) { reset() }
                } else {
                    ModelList(models: models, selection: Binding(get: { provider.model }, set: { provider.model = $0; reset() }))
                }
            }
            result
        } footer: {
            Button(passed ? "Test Again" : "Test") { test() }.buttonStyle(MurmurButtonStyle(height: 32)).disabled(!canTest)
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(MurmurButtonStyle(height: 32)).keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Provider" : "Save") {
                let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(provider, typed.isEmpty ? nil : typed)
            }
            .buttonStyle(MurmurButtonStyle(kind: .primary, height: 32)).disabled(!passed)
        }
    }

    private var blurb: String {
        switch kind {
        case .anthropic, .openAI: "Billed by \(kind.label) to your own account. Murmur adds no fees."
        case .localServer: "A model server running on this Mac. Nothing leaves it."
        case .openAICompatible: "Any server that speaks the OpenAI chat API. Billing, if any, is between you and them."
        case .appleIntelligence: ""
        }
    }

    @ViewBuilder private var result: some View {
        switch phase {
        case .idle: EmptyView()
        case .chooseModel:
            Label("Connected. Choose a model above, then test.", systemImage: "checkmark").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.success)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.successSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .working(let what):
            HStack(spacing: 8) {
                Spinner()
                Text(what).font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary)
            }
        case .passed(let test):
            VStack(alignment: .leading, spacing: 6) {
                Label("Connected · test took \(String(format: "%.1f", test.seconds)) s", systemImage: "checkmark").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.success)
                Text("\(Text("Sent: ").foregroundStyle(Tokens.labelTertiary))\(test.sent)\n\(Text("Got back: ").foregroundStyle(Tokens.labelTertiary))\(Text(test.received).foregroundStyle(Tokens.label))")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.successSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.warning)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func field(_ title: String, note: String? = nil, link: (String, URL)? = nil, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Tokens.labelSecondary)
            control()
            if note != nil || link != nil {
                HStack(spacing: 4) {
                    if let note { Text(note).foregroundStyle(Tokens.labelTertiary) }
                    if let link { Button(link.0) { NSWorkspace.shared.open(link.1) }.buttonStyle(.plain).foregroundStyle(Tokens.accentText) }
                }
                .font(.system(size: 11)).fixedSize(horizontal: link != nil, vertical: true)
            }
        }
    }

    /// Anything that changes what would be sent makes the last test stale.
    private func reset() {
        if !isWorking, phase != .idle { phase = .idle }
    }

    private func test() {
        let key = workingKey
        Task {
            do {
                if models.isEmpty {
                    phase = .working("Listing models…")
                    models = try await router.models(for: provider, key: key)
                }
                if !models.isEmpty, !models.contains(where: { $0.id == provider.model }) {
                    // Anthropic says which models are its small fast line; that suits a clean-up. Otherwise the choice is the user's.
                    let usable = models.filter { ProviderAPI.canCleanText($0.id) }
                    guard let pick = models.first(where: { $0.line == "haiku" }) ?? (usable.count == 1 ? usable.first : nil) else {
                        provider.model = ""
                        phase = .chooseModel
                        return
                    }
                    provider.model = pick.id
                }
                guard !provider.model.isEmpty else { return phase = .failed("The server listed no models. Type a model name, then test again.") }
                provider.supportsEffort = models.first { $0.id == provider.model }?.supportsEffort ?? false
                phase = .working("Sending a test sentence…")
                let result = try await router.test(provider, key: key)
                provider = result.provider
                phase = .passed(result)
            } catch {
                phase = .failed((error as? ProviderError ?? .unreachable).summary)
            }
        }
    }
}

/// The provider's models as a list inside the sheet: a search box when there are many, one row each.
/// Speech, image and embedding models are left out until they are searched for.
private struct ModelList: View {
    let models: [ProviderAPI.Model]
    @Binding var selection: String
    @State private var search = ""

    private var usable: [ProviderAPI.Model] { models.filter { ProviderAPI.canCleanText($0.id) } }
    private var shown: [ProviderAPI.Model] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? usable : models.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if models.count > 6 { SearchField(placeholder: "Search \(models.count) models", text: $search, height: 28) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(shown, id: \.id) { model in row(model).id(model.id) }
                        if shown.isEmpty {
                            Text("No model matches “\(search)”.").font(.mmSub).foregroundStyle(Tokens.labelTertiary).frame(maxWidth: .infinity, minHeight: 30)
                        }
                    }
                    .padding(4)
                }
                .frame(height: min(CGFloat(max(shown.count, 1)) * 31 + 8, 164))
                .background(Tokens.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            let hidden = models.count - usable.count
            if hidden > 0, search.isEmpty {
                Text("\(hidden) speech, image and embedding models are left out. Search to find one.").font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model")
    }

    private func row(_ model: ProviderAPI.Model) -> some View {
        let on = model.id == selection
        return Button { selection = model.id } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.accentText).opacity(on ? 1 : 0).frame(width: 12)
                Text(model.id).font(.system(size: 12.5, weight: on ? .semibold : .regular, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if model.line == "haiku" { Text("fast · good for cleanup").font(.system(size: 11)).foregroundStyle(Tokens.labelTertiary) }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(on ? Tokens.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(HoverRowStyle(cornerRadius: 7))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Sheet D: asked the first time text would go to a host. Declining changes nothing.
struct ProviderConsentSheet: View {
    let provider: ProviderConfig
    var onDecline: () -> Void = {}
    var onAccept: () -> Void = {}

    private var who: String { provider.kind.company ?? provider.hostLabel }

    var body: some View {
        SheetFrame {
            Image(systemName: "cloud").font(.system(size: 18, weight: .medium)).foregroundStyle(Tokens.warning)
                .frame(width: 40, height: 40).background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Send cleanup text to \(who)?").font(.system(size: 17, weight: .bold)).padding(.top, 6)
            Text("Shown once, the first time you pick a provider at this address.").font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary)
        } content: {
            point("checkmark", Tokens.success, Tokens.successSoft, "Audio stays on this Mac.", "Transcription still runs here.")
            point("arrow.up.right", Tokens.warning, Tokens.warningSoft, "The text of each take", "using Cleaned up, plus the preset’s instructions, goes to \(who).")
            point("list.bullet", Tokens.accentText, Tokens.accentSoft, "Every request is logged", "in Privacy › Network log. Offline mode sends nothing.")
            HStack(alignment: .top, spacing: 12) {
                icon("info", Tokens.labelSecondary, Tokens.controlStrong)
                HStack(spacing: 4) {
                    Text("\(Text("\(who)’s data policy applies").fontWeight(.semibold).foregroundStyle(Tokens.label)) to what you send.")
                    if let policy = provider.kind.dataPolicy {
                        Button("Read it") { NSWorkspace.shared.open(policy) }.buttonStyle(.plain).foregroundStyle(Tokens.accentText)
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(Tokens.labelSecondary)
            }
        } footer: {
            Button("Keep It on This Mac", action: onDecline).buttonStyle(MurmurButtonStyle(height: 32)).keyboardShortcut(.cancelAction)
            Button("Use \(provider.name)", action: onAccept).buttonStyle(MurmurButtonStyle(kind: .primary, height: 32))
        }
        .accessibilityAddTraits(.isModal)
    }

    private func icon(_ symbol: String, _ color: Color, _ background: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            .frame(width: 24, height: 24).background(background, in: Circle())
    }

    private func point(_ symbol: String, _ color: Color, _ background: Color, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(symbol, color, background)
            Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(Tokens.label)) \(rest)")
                .font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(Tokens.labelSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
