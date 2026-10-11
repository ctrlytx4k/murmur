import AVFoundation
import AppKit
import ApplicationServices

public nonisolated enum Permission: String, CaseIterable, Sendable {
    case microphone, accessibility, inputMonitoring

    public var name: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// The System Settings pane that grants it.
    var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public nonisolated struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public static let allGranted = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true)

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }

    public var missing: [Permission] { Permission.allCases.filter { !isGranted($0) } }
    public var allGranted: Bool { missing.isEmpty }
}

public protocol PermissionsService: AnyObject {
    /// Always a live read. Never cached across launches.
    func snapshot() -> PermissionSnapshot
    /// Shows the system prompt where there is one, otherwise opens the right System Settings pane.
    func request(_ permission: Permission)
}

public final class LivePermissionsService: PermissionsService {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess())
    }

    public func request(_ permission: Permission) {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .accessibility:
            // The system prompt only appears the first time; opening the pane always works.
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            NSWorkspace.shared.open(permission.settingsURL)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            NSWorkspace.shared.open(permission.settingsURL)
        }
    }
}
