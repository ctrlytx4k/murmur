import SwiftUI

/// What the views can ask the app to do. Keeps window management out of the views.
struct AppActions {
    var openSettings: (SettingsPane?) -> Void = { _ in }
    var openHistory: () -> Void = {}
    var openOverview: () -> Void = {}
    var openMeetings: () -> Void = {}
    var openOnboarding: (Permission?) -> Void = { _ in }
    var showAbout: () -> Void = {}
    var showAcknowledgements: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var closeDropdown: () -> Void = {}
    var quit: () -> Void = {}
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions()
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }
    /// Shown as "Read the code" in onboarding.
    static let repository = URL(string: "https://github.com/ctrlytx4k/murmur")
    /// Where new versions are published. Opening it in the browser is the whole update check for now.
    static let releases = URL(string: "https://github.com/ctrlytx4k/murmur/releases")!
}

/// m:ss since a start date, ticking once a second.
struct ElapsedTime: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
        }
    }
}
