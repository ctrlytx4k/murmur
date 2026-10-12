import Foundation
import Testing
@testable import MurmurKit

@MainActor
@Suite struct SettingsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")! }

    @Test func aFreshInstallStartsWithTheDocumentedDefaults() {
        let settings = SettingsStore(defaults: defaults())
        #expect(settings.shortcut == .rightOption)
        #expect(settings.shortcut.keycaps == ["Right ⌥"] && settings.shortcut.isModifierOnly && !settings.shortcut.isDoubleTap)
        #expect(settings.behavior == .pushToTalk && settings.doubleTapToLock)
        #expect(settings.mode == .raw && !settings.cleanupEnabled && settings.cleanupPreset == .lightTouch)
        #expect(settings.modelID == "apple-speech" && settings.language == "English")
        #expect(settings.insertMethod == .pasting && settings.restoresClipboard && settings.addsTrailingSpace)
        #expect(settings.overlay == OverlayAppearance() && settings.overlay.position == .bottom)
        #expect(!settings.offlineMode && settings.retention == .month)
        #expect(!settings.hasCompletedOnboarding && settings.microphoneID == nil)
        Accent.current = .ice
    }

    @Test func valuesSavedByOlderBuildsFallBackSafely() {
        let d = defaults()
        d.set("Near text cursor", forKey: "overlayPosition")
        d.set("command", forKey: "mode")
        d.set("not-a-preset", forKey: "cleanupPreset")
        let settings = SettingsStore(defaults: d)
        #expect(settings.overlay.position == .bottom)
        #expect(settings.mode == .raw)
        #expect(settings.cleanupPreset == .lightTouch)
        Accent.current = .ice
    }

    @Test func returnEndsATakeInToggleAndDoubleTapOnly() {
        let settings = SettingsStore(defaults: defaults())
        settings.shortcut = .optionSpace
        settings.behavior = .pushToTalk
        #expect(!settings.hotkeyBindings.returnCommits)
        settings.behavior = .toggle
        #expect(settings.hotkeyBindings.returnCommits)
        settings.behavior = .pushToTalk
        settings.shortcut = .doubleTapOption
        #expect(settings.hotkeyBindings.returnCommits)
        #expect(settings.hotkeyBindings.dictation == .doubleTapOption)
        Accent.current = .ice
    }

    @Test func everySettingSurvivesARelaunch() {
        let d = defaults()
        let settings = SettingsStore(defaults: d)
        settings.shortcut = .optionSpace
        settings.behavior = .toggle
        settings.mode = .cleaned
        settings.cleanupEnabled = true
        settings.cleanupPreset = .notes
        settings.customInstructions = "Be brief."
        settings.appPresets = [AppPreset(bundleIdentifier: "com.apple.mail", name: "Mail", preset: "raw")]
        settings.language = "German"
        settings.overlay.position = .top
        settings.retention = .forever
        settings.offlineMode = true
        settings.insertMethod = .typing
        settings.maxLength = .fifteen
        settings.onboardingStep = 3

        let reopened = SettingsStore(defaults: d)
        #expect(reopened.shortcut == .optionSpace && reopened.behavior == .toggle)
        #expect(reopened.mode == .cleaned && reopened.cleanupEnabled && reopened.cleanupPreset == .notes)
        #expect(reopened.customInstructions == "Be brief." && reopened.appPresets.first?.name == "Mail")
        #expect(reopened.language == "German" && reopened.overlay.position == .top)
        #expect(reopened.retention == .forever && reopened.offlineMode)
        #expect(reopened.insertMethod == .typing && reopened.maxLength == .fifteen && reopened.onboardingStep == 3)
        Accent.current = .ice
    }

    @Test func diagnosticsCarrySettingsOnly() {
        let keys = Set(SettingsStore(defaults: defaults()).diagnostics().keys)
        #expect(keys.contains("shortcut") && keys.contains("model") && keys.contains("macOS"))
        #expect(keys.isDisjoint(with: ["history", "text", "transcript", "audio", "path", "microphoneID"]))
        Accent.current = .ice
    }

    @Test func modesCycleThroughTheOfferedOnesOnly() {
        #expect(DictationMode.raw.next == .cleaned)
        #expect(DictationMode.cleaned.next == .raw)
        #expect(DictationMode.command.next == .raw)
        for mode in DictationMode.offered { #expect(!mode.label.isEmpty && !mode.summary.isEmpty && !mode.symbol.isEmpty) }
    }

    @Test func everyBuiltInPresetHasInstructions() {
        for preset in CleanupPreset.allCases where preset != .custom {
            #expect(!preset.builtInInstructions.isEmpty && !preset.name.isEmpty && !preset.summary.isEmpty)
        }
        #expect(CleanupPreset.custom.builtInInstructions.isEmpty)
        #expect(SettingsStore.MaxLength.five.seconds == 300)
        #expect(SettingsStore.Retention.never.days == 0 && SettingsStore.Retention.forever.days == nil)
    }
}

@MainActor
@Suite struct StoreTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "murmur-tests-\(UUID().uuidString)")! }

    private func entry(_ text: String, daysAgo: Double = 0) -> HistoryEntry {
        HistoryEntry(date: Date().addingTimeInterval(-daysAgo * 86_400), appName: "Notes", bundleIdentifier: nil, mode: .raw, text: text, raw: nil, audioSeconds: 2, engine: "fake")
    }

    @Test func historyIsNewestFirstAndCanBeTrimmed() {
        let d = defaults()
        let history = HistoryStore(defaults: d)
        history.add(entry("one"), retention: .forever)
        history.add(entry("two"), retention: .forever)
        #expect(history.entries.map(\.text) == ["two", "one"])
        history.delete(history.entries[0].id)
        #expect(history.entries.map(\.text) == ["one"])
        #expect(HistoryStore(defaults: d).entries.map(\.text) == ["one"])
        history.clear()
        #expect(history.entries.isEmpty && HistoryStore(defaults: d).entries.isEmpty)
    }

    @Test func keepForeverNeverPrunes() {
        let history = HistoryStore(defaults: defaults())
        history.add(entry("ancient", daysAgo: 4000), retention: .forever)
        history.prune(retention: .forever)
        #expect(history.entries.count == 1)
        history.prune(retention: .week)
        #expect(history.entries.isEmpty)
    }

    @Test func theNetworkLogRecordsNewestFirstAndClears() {
        let d = defaults()
        let log = NetworkLog(defaults: d)
        log.record(host: "huggingface.co", reason: "Model download", bytes: 10)
        log.record(host: "Apple (via macOS)", reason: "Speech language download", bytes: 0)
        #expect(log.entries.map(\.host) == ["Apple (via macOS)", "huggingface.co"])
        #expect(NetworkLog(defaults: d).entries.count == 2)
        log.clear()
        #expect(NetworkLog(defaults: d).entries.isEmpty)
    }

    @Test func theModelCatalogTracksDownloads() {
        let catalog = ModelCatalog(parakeetStatus: .available)
        #expect(catalog.model("apple-speech")?.isUsable == true)
        #expect(catalog.model("parakeet-v3")?.isUsable == false)
        #expect(catalog.model("missing") == nil)
        #expect(catalog.languageStatus == .ready)

        var asked: [String] = []
        catalog.onDownload = { asked.append($0) }
        catalog.downloadError = "The download stopped."
        catalog.requestDownload("parakeet-v3")
        #expect(asked == ["parakeet-v3"] && catalog.downloadError == nil && catalog.downloadsAreReal)

        catalog.setStatus(.downloading(0.5), for: "parakeet-v3")
        #expect(catalog.model("parakeet-v3")?.status == .downloading(0.5))
        catalog.setStatus(.installed, for: "parakeet-v3")
        #expect(catalog.model("parakeet-v3")?.isUsable == true)
        catalog.cancelDownload("parakeet-v3")
        #expect(catalog.model("parakeet-v3")?.status == .available)
    }

    @Test func importingTwiceAddsNothingNew() {
        let dictionary = DictionaryStore(defaults: defaults())
        #expect(dictionary.importData(Data("kube cuttle, kubectl\npost gres, Postgres\nbroken line\n".utf8)) == 2)
        #expect(dictionary.importData(Data("kube cuttle, kubectl\n".utf8)) == 0)
        #expect(dictionary.importData(Data([0xFF, 0xFE, 0x00])) == 0)
        dictionary.snippets = [Snippet(trigger: "today", text: "{date}"), Snippet(trigger: "sig", text: "Thanks")]
        #expect(dictionary.snippets[0].isDynamic && !dictionary.snippets[1].isDynamic)
        let copy = DictionaryStore(defaults: defaults())
        #expect(copy.importData(dictionary.exportJSON()) == 4)
        #expect(copy.entries.map(\.written) == ["kubectl", "Postgres"])
    }

    @Test func everyLanguageOnTheListHasALocale() {
        for language in SettingsStore.languages where language != "English" {
            #expect(EngineRouter.localeIdentifier(for: language) != "en-US", "\(language) falls back to English")
        }
        #expect(EngineRouter.localeIdentifier(for: "German") == "de-DE")
        #expect(EngineRouter.localeIdentifier(for: "Klingon") == "en-US")
    }

    @Test func shortcutsDescribeThemselvesAndRoundTrip() throws {
        #expect(Shortcut.doubleTapOption.isModifierOnly && Shortcut.doubleTapOption.spokenName == "double-tap ⌥")
        #expect(Shortcut.optionSpace.spokenName == "⌥ Space")
        #expect(Shortcut(keyCode: 49, modifiers: [.command, .option]).systemConflict != nil)
        let shortcut = Shortcut(keyCode: 9, modifiers: [.control, .option, .capsLock])
        // Only command, option, control and shift count.
        #expect(shortcut.modifierFlags == [.control, .option])
        #expect(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut)) == shortcut)
    }

    @Test func everyFailureHasWordsForTheUser() {
        let errors: [DictationError] = [
            .microphoneDenied, .accessibilityDenied, .secureInput, .nothingHeard, .noInputDevice,
            .insertionFailed(appName: "Notes"), .transcriptionFailed("why"), .engineUnavailable("why"), .modelNotReady(name: "parakeet-v3", progress: 0.4),
        ]
        for error in errors { #expect(!error.title.isEmpty && !error.message.isEmpty) }
        #expect(DictationError.insertionFailed(appName: "Notes").title.contains("Notes"))
        #expect(DictationError.modelNotReady(name: "parakeet-v3", progress: 0.4).message.contains("40%"))
        // Red is for a take that went wrong; amber for what the user can fix or what was handled safely.
        #expect(!DictationError.insertionFailed(appName: "Notes").isWarning && DictationError.secureInput.isWarning)
        for permission in Permission.allCases { #expect(DictationError.missing(permission).isWarning) }
    }

    @Test func permissionSnapshotsListWhatIsMissing() {
        #expect(PermissionSnapshot.allGranted.allGranted && PermissionSnapshot.allGranted.missing.isEmpty)
        let snapshot = PermissionSnapshot(microphone: true, accessibility: false)
        #expect(snapshot.missing == [.accessibility] && !snapshot.allGranted)
        // Two permissions, and no third: Input Monitoring is never asked for.
        #expect(Permission.allCases == [.microphone, .accessibility])
        #expect(snapshot.isGranted(.microphone) && !snapshot.isGranted(.accessibility))
    }

    @Test func aSavedMicrophoneThatIsUnpluggedIsListedAsNotConnected() {
        let connected = AudioDevices.menuOptions(saved: nil, savedName: nil)
        #expect(connected.options.first?.label == "System Default" && connected.options.first?.value == nil)
        #expect(connected.disconnected.isEmpty)

        let gone = AudioDevices.menuOptions(saved: "murmur-tests-no-such-device", savedName: "Old Mic")
        #expect(gone.options.last?.label == "Old Mic")
        #expect(gone.details["murmur-tests-no-such-device"] == "Not connected · using default")
        #expect(gone.disconnected == ["murmur-tests-no-such-device"])
        #expect(AudioDevices.menuOptions(saved: "murmur-tests-no-such-device", savedName: nil).options.last?.label == "Saved microphone")
    }

    @Test func cleanupRepliesAreTidiedBeforeTheyAreJudged() {
        #expect(CleanupCheck.tidy("<transcript>\nHello there.  \n</transcript>") == "Hello there.")
        #expect(CleanupCheck.tidy("\"Hello there.\"") == "Hello there.")
        #expect(CleanupCheck.tidy("“Hello there.”") == "Hello there.")
        #expect(!CleanupCheck.accepts(raw: "send the report", cleaned: ""))
        #expect(CleanupCheck.accepts(raw: "um send the report by tuesday", cleaned: "Send the report by Tuesday."))
    }

    @Test func menuRowsKnowTheirHeight() {
        #expect(GlassMenuItem(title: "Plain").height == 32)
        #expect(GlassMenuItem(title: "Two lines", detail: "More").height == 48)
        #expect(GlassMenuItem(title: "Icon", symbol: "mic").height == 48)
        #expect(!GlassMenuItem.separator.isRow && !GlassMenuItem.header("Input").isRow && GlassMenuItem(title: "Row").isRow)
    }

    @Test func anOverlayPanelCollapsesAMomentAfterAChoice() async throws {
        let panels = OverlayPanelState()
        panels.open = .mode
        panels.collapseSoon()
        #expect(panels.open == .mode)
        // Polls, so a busy machine does not fail it.
        for _ in 0..<200 where panels.open != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panels.open == nil)
    }
}
