import Foundation
import Observation
import ServiceManagement

public nonisolated enum DictationMode: String, CaseIterable, Codable, Sendable {
    case raw, cleaned, command

    public var label: String {
        switch self {
        case .raw: "Raw"
        case .cleaned: "Cleaned up"
        case .command: "Command"
        }
    }

    /// One line on what the mode does, for menus.
    public var summary: String {
        switch self {
        case .raw: "Exactly what you said"
        case .cleaned: "Fixes fillers, punctuation, casing"
        case .command: "Say an edit for the selected text"
        }
    }

    public var shortLabel: String { self == .cleaned ? "Cleaned" : label }

    public var symbol: String {
        switch self {
        case .raw: "waveform"
        case .cleaned: "text.badge.checkmark"
        case .command: "command"
        }
    }

    /// Command mode is not built yet, so it is not offered. The case stays for saved history.
    public static let offered: [DictationMode] = [.raw, .cleaned]

    public var next: DictationMode {
        let all = Self.offered
        return all[((all.firstIndex(of: self) ?? -1) + 1) % all.count]
    }
}

/// A cleanup preset chosen for one app.
public nonisolated struct AppPreset: Codable, Equatable, Identifiable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    /// A `CleanupPreset` raw value, or "raw" for no cleanup.
    public var preset: String
    public var id: String { bundleIdentifier }
}

public nonisolated enum CleanupPreset: String, CaseIterable, Sendable {
    case lightTouch, polished, notes, custom

    public var name: String {
        switch self {
        case .lightTouch: "Light touch"
        case .polished: "Polished"
        case .notes: "Notes"
        case .custom: "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .lightTouch: "Punctuation, casing, no fillers"
        case .polished: "Tighter sentences, same meaning"
        case .notes: "Short bullet points"
        case .custom: "Your own instructions"
        }
    }

    public var builtInInstructions: String {
        switch self {
        case .lightTouch: "Fix punctuation, capitalization and obvious mis-hearings. Remove filler words (um, uh, like). Keep the speaker’s wording and tone. Never add new content."
        case .polished: "Rewrite into clear, tight sentences. Keep the meaning, the facts and the speaker’s voice. A question stays a question and a request stays a request, addressed to the same person. Never add new content."
        case .notes: "Turn the text into short bullet points, one idea per line, each starting with a hyphen. Keep names, numbers and dates exactly. A question stays a question and a request stays a request. Never add new content."
        case .custom: ""
        }
    }
}

/// User settings. Local only, stored in UserDefaults.
@Observable
public final class SettingsStore {
    public enum Behavior: String, Sendable { case pushToTalk, toggle }
    public enum Appearance: String, Sendable { case auto, light, dark }
    public enum SoundSet: String, CaseIterable, Sendable { case soft = "Soft", click = "Click", chime = "Chime" }
    public enum Retention: String, CaseIterable, Sendable { case never = "Don’t keep", week = "7 days", month = "30 days", quarter = "90 days", forever = "Forever"
        public var days: Int? {
            switch self {
            case .never: 0
            case .week: 7
            case .month: 30
            case .quarter: 90
            case .forever: nil
            }
        }
    }
    public enum InsertMethod: String, CaseIterable, Sendable { case pasting = "Pasting", typing = "Typing" }
    public enum MaxLength: String, CaseIterable, Sendable { case one = "1 minute", five = "5 minutes", fifteen = "15 minutes", thirty = "30 minutes"
        public var seconds: Double {
            switch self {
            case .one: 60
            case .five: 300
            case .fifteen: 900
            case .thirty: 1800
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    // General
    public var showInDock: Bool { didSet { save(showInDock, "showInDock") } }
    public var soundsEnabled: Bool { didSet { save(soundsEnabled, "soundsEnabled") } }
    public var soundSet: SoundSet { didSet { save(soundSet.rawValue, "soundSet") } }
    public var accent: Accent { didSet { save(accent.rawValue, "accent"); Accent.current = accent } }
    public var appearance: Appearance { didSet { save(appearance.rawValue, "appearance") } }
    /// Nil means "follow the system default input".
    public var microphoneID: String? { didSet {
        save(microphoneID, "microphoneID")
        // Kept so a microphone that is later unplugged can still be shown by name.
        if let name = microphoneID.flatMap({ id in AudioDevices.inputs().first { $0.id == id }?.name }) { microphoneName = name }
    } }
    public private(set) var microphoneName: String? { didSet { save(microphoneName, "microphoneName") } }
    public var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }
    /// Where onboarding got to. macOS quits an app when some permissions are switched in System Settings,
    /// so on the next launch onboarding picks up at the same step instead of starting over.
    public var onboardingStep: Int { didSet { save(onboardingStep, "onboardingStep") } }

    // Overlay
    public var overlay: OverlayAppearance { didSet {
        let allowed = overlay.clamped
        if allowed != overlay { overlay = allowed } else { saveCodable(overlay, "overlayAppearance") }
    } }

    // Hotkeys
    public var shortcut: Shortcut { didSet { saveCodable(shortcut, "shortcut") } }
    public var behavior: Behavior { didSet { save(behavior.rawValue, "behavior") } }
    public var doubleTapToLock: Bool { didSet { save(doubleTapToLock, "doubleTapToLock") } }
    public var cycleModeShortcut: Shortcut { didSet { saveCodable(cycleModeShortcut, "cycleModeShortcut") } }
    public var reinsertShortcut: Shortcut { didSet { saveCodable(reinsertShortcut, "reinsertShortcut") } }
    public var historyShortcut: Shortcut { didSet { saveCodable(historyShortcut, "historyShortcut") } }
    /// Shortcuts the user chose to keep despite a system conflict, by spoken name.
    public var acceptedConflicts: [String] { didSet { save(acceptedConflicts, "acceptedConflicts") } }

    // Dictation
    public var mode: DictationMode { didSet { save(mode.rawValue, "mode") } }

    // Voice engine
    public var modelID: String { didSet { save(modelID, "modelID") } }
    public var language: String { didSet { save(language, "language") } }

    // AI cleanup
    public var cleanupEnabled: Bool { didSet { save(cleanupEnabled, "cleanupEnabled") } }
    public var cleanupPreset: CleanupPreset { didSet { save(cleanupPreset.rawValue, "cleanupPreset") } }
    public var customInstructions: String { didSet { save(customInstructions, "customInstructions") } }
    public var appPresets: [AppPreset] { didSet { saveCodable(appPresets, "appPresets") } }

    // Privacy
    public var offlineMode: Bool { didSet { save(offlineMode, "offlineMode") } }
    public var logsNetworkActivity: Bool { didSet { save(logsNetworkActivity, "logsNetworkActivity") } }
    public var retention: Retention { didSet { save(retention.rawValue, "retention") } }
    /// Off: no take is counted. Rows already counted stay until Reset stats.
    public var keepStats: Bool { didSet { save(keepStats, "keepStats") } }
    /// The typing speed "time saved" is measured against. Changing it recalculates every take.
    public var typingWPM: Int { didSet {
        let allowed = min(max(typingWPM, Self.typingWPMRange.lowerBound), Self.typingWPMRange.upperBound)
        if allowed != typingWPM { typingWPM = allowed } else { save(typingWPM, "typingWPM") }
    } }
    public static let typingWPMRange = 10...150

    // Advanced
    public var insertMethod: InsertMethod { didSet { save(insertMethod.rawValue, "insertMethod") } }
    public var restoresClipboard: Bool { didSet { save(restoresClipboard, "restoresClipboard") } }
    public var addsTrailingSpace: Bool { didSet { save(addsTrailingSpace, "addsTrailingSpace") } }
    public var maxLength: MaxLength { didSet { save(maxLength.rawValue, "maxLength") } }
    public var debugLog: Bool { didSet { save(debugLog, "debugLog"); DebugLog.isEnabled = debugLog } }

    /// Mirrors SMAppService, which is the source of truth. Refreshed whenever Settings opens.
    public private(set) var launchAtLogin = false
    public private(set) var launchAtLoginError: String?

    public static let languages = ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Polish", "Ukrainian", "Russian"]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func raw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func codable<T: Decodable>(_ key: String, _ fallback: T) -> T {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback
        }

        showInDock = bool("showInDock", false)
        soundsEnabled = bool("soundsEnabled", true)
        soundSet = raw("soundSet", .soft)
        accent = raw("accent", .ice)
        // Light is the default design; dark and Auto are there for people who ask for them.
        appearance = raw("appearance", .light)
        microphoneID = defaults.string(forKey: "microphoneID")
        microphoneName = defaults.string(forKey: "microphoneName")
        hasCompletedOnboarding = bool("hasCompletedOnboarding", false)
        onboardingStep = defaults.integer(forKey: "onboardingStep")

        if defaults.data(forKey: "overlayAppearance") == nil {
            // The position used to live in General under its own key. Carry it over once, then drop the old key.
            var migrated = OverlayAppearance()
            if defaults.string(forKey: "overlayPosition") == "Top of screen" { migrated.position = .top }
            defaults.set(try? JSONEncoder().encode(migrated), forKey: "overlayAppearance")
            defaults.removeObject(forKey: "overlayPosition")
        }
        overlay = codable("overlayAppearance", OverlayAppearance())

        shortcut = codable("shortcut", .rightOption)
        behavior = raw("behavior", .pushToTalk)
        doubleTapToLock = bool("doubleTapToLock", true)
        cycleModeShortcut = codable("cycleModeShortcut", Shortcut(keyCode: 46, modifiers: .option))
        reinsertShortcut = codable("reinsertShortcut", Shortcut(keyCode: 9, modifiers: [.control, .option]))
        historyShortcut = codable("historyShortcut", Shortcut(keyCode: 4, modifiers: [.control, .option]))
        acceptedConflicts = defaults.stringArray(forKey: "acceptedConflicts") ?? []

        let savedMode: DictationMode = raw("mode", .raw)
        mode = DictationMode.offered.contains(savedMode) ? savedMode : .raw
        // The built-in engine needs no download, so it is the one that works out of the box.
        modelID = defaults.string(forKey: "modelID") ?? "apple-speech"
        language = defaults.string(forKey: "language") ?? "English"

        cleanupEnabled = bool("cleanupEnabled", false)
        cleanupPreset = raw("cleanupPreset", .lightTouch)
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        appPresets = codable("appPresets", [])

        offlineMode = bool("offlineMode", false)
        logsNetworkActivity = bool("logsNetworkActivity", true)
        retention = raw("retention", .month)
        keepStats = bool("keepStats", true)
        let savedWPM = defaults.object(forKey: "typingWPM") as? Int ?? 40
        typingWPM = min(max(savedWPM, Self.typingWPMRange.lowerBound), Self.typingWPMRange.upperBound)

        insertMethod = raw("insertMethod", .pasting)
        restoresClipboard = bool("restoresClipboard", true)
        addsTrailingSpace = bool("addsTrailingSpace", true)
        maxLength = raw("maxLength", .five)
        debugLog = bool("debugLog", false)

        Accent.current = accent
        DebugLog.isEnabled = debugLog
    }

    /// Puts every setting back to its default. Onboarding stays completed.
    public func resetAll() {
        let fresh = SettingsStore(defaults: UserDefaults(suiteName: "murmur-defaults-\(UUID().uuidString)")!)
        showInDock = fresh.showInDock; soundsEnabled = fresh.soundsEnabled; soundSet = fresh.soundSet
        overlay = OverlayAppearance(); accent = fresh.accent; appearance = fresh.appearance
        microphoneID = nil
        shortcut = fresh.shortcut; behavior = fresh.behavior; doubleTapToLock = fresh.doubleTapToLock
        cycleModeShortcut = fresh.cycleModeShortcut; reinsertShortcut = fresh.reinsertShortcut
        historyShortcut = fresh.historyShortcut; acceptedConflicts = []
        mode = fresh.mode; modelID = fresh.modelID
        language = fresh.language
        cleanupEnabled = fresh.cleanupEnabled; cleanupPreset = fresh.cleanupPreset; customInstructions = ""; appPresets = []
        offlineMode = fresh.offlineMode; logsNetworkActivity = fresh.logsNetworkActivity
        retention = fresh.retention; keepStats = fresh.keepStats; typingWPM = fresh.typingWPM
        insertMethod = fresh.insertMethod; restoresClipboard = fresh.restoresClipboard
        addsTrailingSpace = fresh.addsTrailingSpace
        maxLength = fresh.maxLength; debugLog = fresh.debugLog
    }

    /// Settings as plain text for a bug report. No transcripts, no audio, no paths.
    public func diagnostics() -> [String: String] {
        [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "shortcut": shortcut.spokenName, "behavior": behavior.rawValue, "mode": mode.rawValue,
            "model": modelID, "language": language,
            "cleanup": cleanupEnabled ? cleanupPreset.rawValue : "off", "insertBy": insertMethod.rawValue,
            "restoresClipboard": String(restoresClipboard), "offlineMode": String(offlineMode),
            "retention": retention.rawValue, "keepStats": String(keepStats), "appearance": appearance.rawValue, "accent": accent.rawValue,
            "overlay": "\(overlay.material.rawValue) \(overlay.size.rawValue) \(overlay.position.rawValue)",
        ]
    }

    public func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            // Typically: not running from a signed app bundle in /Applications.
            launchAtLoginError = "Couldn’t change this: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    public var hotkeyBindings: HotkeyBindings {
        HotkeyBindings(dictation: shortcut, cycleMode: cycleModeShortcut, reinsert: reinsertShortcut, history: historyShortcut, returnCommits: behavior == .toggle || shortcut.isDoubleTap)
    }

    private func save(_ value: Any?, _ key: String) { defaults.set(value, forKey: key) }
    private func saveCodable(_ value: some Encodable, _ key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
}
