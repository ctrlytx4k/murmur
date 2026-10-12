import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Real app icons, looked up from the bundle identifier when they are drawn. Nothing is bundled.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func systemLocation(of bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// What macOS shows for an app it knows nothing about.
    static let generic = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The app's own icon, or nil when the app is not installed on this Mac.
    static func icon(forBundleIdentifier id: String, locate: @MainActor (String) -> URL? = systemLocation) -> NSImage? {
        if let cached = cache[id] { return cached }
        // A miss is not cached: the app may be installed later.
        guard let url = locate(id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = icon
        return icon
    }

    /// Always an icon: the app's own, or the generic one for an app that is gone.
    static func resolve(_ bundleIdentifier: String?, locate: @MainActor (String) -> URL? = systemLocation) -> (image: NSImage, isGeneric: Bool) {
        if let icon = bundleIdentifier.flatMap({ icon(forBundleIdentifier: $0, locate: locate) }) { return (icon, false) }
        return (generic, true)
    }
}

/// An app's icon as the system draws it, never masked or tinted. The generic app icon when the app is gone.
struct AppBadge: View {
    let name: String
    let bundleIdentifier: String?
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: AppIcons.resolve(bundleIdentifier).image).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
