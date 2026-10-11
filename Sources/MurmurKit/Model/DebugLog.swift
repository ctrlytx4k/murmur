import Foundation
import os

/// The optional debug log (Settings > Advanced). Timing and events only: never audio, never transcript text.
/// Written to ~/Library/Logs/Murmur/murmur.log.
public nonisolated enum DebugLog {
    private static let enabled = OSAllocatedUnfairLock(initialState: false)
    private static let queue = DispatchQueue(label: "murmur.debug-log")

    public static var isEnabled: Bool {
        get { enabled.withLock { $0 } }
        set { enabled.withLock { $0 = newValue } }
    }

    public static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Murmur/murmur.log")
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message())\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
