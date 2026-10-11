import Foundation
import Observation
import ServiceManagement

/// User settings. Local only, stored in UserDefaults.
@Observable
public final class SettingsStore {
    public enum Behavior: String, Sendable { case pushToTalk, toggle }
    public enum Appearance: String, Sendable { case auto, light, dark }

    @ObservationIgnored private let defaults: UserDefaults

    public var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Key.shortcut) }
    }
    public var behavior: Behavior {
        didSet { defaults.set(behavior.rawValue, forKey: Key.behavior) }
    }
    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    /// Nil means "follow the system default input".
    public var microphoneID: String? {
        didSet { defaults.set(microphoneID, forKey: Key.microphone) }
    }
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded) }
    }

    /// Mirrors SMAppService, which is the source of truth. Refreshed whenever Settings opens.
    public private(set) var launchAtLogin = false
    public private(set) var launchAtLoginError: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = defaults.data(forKey: Key.shortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .optionSpace
        behavior = defaults.string(forKey: Key.behavior).flatMap(Behavior.init) ?? .pushToTalk
        // Light is the default design; dark and Auto are there for people who ask for them.
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .light
        microphoneID = defaults.string(forKey: Key.microphone)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
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

    private enum Key {
        static let shortcut = "shortcut"
        static let behavior = "behavior"
        static let appearance = "appearance"
        static let microphone = "microphoneID"
        static let onboarded = "hasCompletedOnboarding"
    }
}
