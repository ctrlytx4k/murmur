import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The scripted part of the insertion matrix: opens each app, inserts a known sentence the way a
/// take would, reads it back and checks the clipboard came back. Run it through LaunchServices so
/// it has the app's own Accessibility grant:
///   open -n build/Murmur.app --args --matrix <results file>
/// It drives the keyboard for about a minute, so it asks first.
enum InsertionMatrix {
    private static let sentence = "murmur matrix one two three"
    private static let clipboardMarker = "murmur-matrix-clipboard"

    private struct Row {
        var name: String
        var inserted = "not run"
        var clipboard = "-"
        var note = ""
    }

    static func run(output: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            let rows = await runAll()
            var lines = ["| Target | Text inserted | Clipboard restored | Notes |", "|---|---|---|---|"]
            lines += rows.map { "| \($0.name) | \($0.inserted) | \($0.clipboard) | \($0.note) |" }
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(toFile: output, atomically: true, encoding: .utf8)
            print(report)
            exit(0)
        }
        app.run()
    }

    private static func runAll() async -> [Row] {
        guard AXIsProcessTrusted() else { return [Row(name: "all", inserted: "not run", note: "Accessibility is not granted to this build")] }
        let previous = NSWorkspace.shared.frontmostApplication

        let alert = NSAlert()
        alert.messageText = "Run Murmur’s insertion tests?"
        alert.informativeText = "Murmur will open Notes, Terminal, Safari and Chrome and type a test sentence into each. It takes about a minute. Please don’t touch the keyboard or mouse until it says it has finished."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return [Row(name: "all", inserted: "not run", note: "Cancelled")] }

        let pasteboard = NSPasteboard.general
        let usersClipboard = PasteboardSnapshot.take(pasteboard)
        defer { usersClipboard.restore(to: pasteboard) }

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "murmur-matrix-\(UUID().uuidString)")!)
        let insertion = PasteInsertion(settings: settings)
        let secureAtStart = insertion.isSecureInputActive
        var rows: [Row] = []

        rows.append(await notes(insertion))
        rows.append(await terminal(insertion))
        let pages = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-matrix", isDirectory: true)
        try? FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        for (browser, id) in [("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome")] {
            rows.append(await web(insertion, name: "\(browser) textarea", browser: id, page: page("textarea", in: pages, body: "<textarea id=t style='width:90%;height:200px'></textarea>", value: "t.value")))
            rows.append(await web(insertion, name: "\(browser) contenteditable", browser: id, page: page("editable", in: pages, body: "<div id=t contenteditable style='border:1px solid;min-height:200px'></div>", value: "t.innerText")))
        }
        var password = await web(insertion, name: "Password field (Safari)", browser: "com.apple.Safari", page: page("password", in: pages, body: "<input id=t type=password>", value: "'x'.repeat(t.value.length)"), secure: true)
        if secureAtStart { password.note += " Secure input was already on before the run, so this row proves little." }
        rows.append(password)

        previous?.activate()
        let done = NSAlert()
        done.messageText = "Insertion tests finished"
        done.informativeText = "You can use your Mac again."
        NSApp.activate()
        done.runModal()
        return rows
    }

    // MARK: targets

    private static func notes(_ insertion: PasteInsertion) async -> Row {
        var row = Row(name: "Notes")
        guard await bringToFront("com.apple.Notes") else { return fail(row, "Notes did not come to the front") }
        press(kVK_ANSI_N, .maskCommand)
        await pause(1.5)
        guard let receipt = await insert(insertion, into: "com.apple.Notes", row: &row) else { return row }
        await pause(0.6)
        let value = focusedValue() ?? ""
        row.inserted = value.contains(sentence) ? "yes" : "NO"
        if !value.contains(sentence) { row.note += "Read back \(value.count) characters without the sentence. " }
        // Undo doubles as the clean-up: an empty note is discarded by Notes.
        let undone = await insertion.undo(receipt)
        await pause(0.6)
        let after = focusedValue() ?? ""
        row.note += undone && !after.contains(sentence) ? "Undo removed it." : "Undo did NOT remove it; a test note is left behind."
        return row
    }

    private static func terminal(_ insertion: PasteInsertion) async -> Row {
        var row = Row(name: "Terminal")
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
        guard await bringToFront("com.apple.Terminal") else { return fail(row, "Terminal did not come to the front") }
        if wasRunning { press(kVK_ANSI_N, .maskCommand) }
        await pause(2)
        guard await insert(insertion, into: "com.apple.Terminal", row: &row) != nil else { return row }
        await pause(0.6)
        let value = focusedValue() ?? ""
        row.inserted = value.contains(sentence) ? "yes" : "NO"
        if !value.contains(sentence) { row.note += "Read back \(value.count) characters without the sentence. " }
        // Clear the line without running it, then close the test window.
        press(kVK_ANSI_U, .maskControl)
        await pause(0.2)
        if frontmost == "com.apple.Terminal" { press(kVK_ANSI_W, .maskCommand) }
        await pause(0.5)
        return row
    }

    /// The page copies whatever is typed into its title, which Accessibility can read from the window
    /// without the browser's own web accessibility being switched on.
    private static func web(_ insertion: PasteInsertion, name: String, browser: String, page: URL, secure: Bool = false) async -> Row {
        var row = Row(name: name)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else { return fail(row, "Not installed") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.open([page], withApplicationAt: appURL, configuration: configuration)
        guard await waitFor(8, { frontmost == browser && (windowTitle(of: browser) ?? "").contains("MM-READY") }) else {
            return fail(row, "The test page did not open in front")
        }
        await pause(0.8)
        // A browser that was just launched can hand focus away once while it settles.
        if frontmost != browser, await bringToFront(browser) { await pause(0.8) }
        defer { if frontmost == browser, (windowTitle(of: browser) ?? "").contains("MM") { press(kVK_ANSI_W, .maskCommand) } }

        if secure {
            let detected = insertion.isSecureInputActive
            row.inserted = "n/a"
            row.note = detected ? "Secure input detected, so a take here is discarded." : "Secure input was NOT detected."
            await pause(0.3)
            return row
        }
        guard await insert(insertion, into: browser, row: &row) != nil else { return row }
        _ = await waitFor(3, { (windowTitle(of: browser) ?? "").contains("MM[") })
        let title = windowTitle(of: browser) ?? ""
        row.inserted = title.contains("MM[\(sentence)") ? "yes" : "NO"
        if !title.contains("MM[\(sentence)") { row.note += "The page did not receive the sentence. " }
        await pause(0.3)
        return row
    }

    private static func page(_ name: String, in directory: URL, body: String, value: String) -> URL {
        let url = directory.appendingPathComponent("\(name).html")
        let html = """
        <!doctype html><meta charset="utf-8"><title>MM-LOADING</title>
        <p>Murmur insertion test. This tab closes by itself.</p>\(body)
        <script>
        const t = document.getElementById('t');
        t.addEventListener('input', () => { document.title = 'MM[' + \(value) + ']'; });
        t.focus();
        document.title = 'MM-READY';
        </script>
        """
        try? html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: steps

    /// Seeds the clipboard, inserts, and records whether the seed came back.
    private static func insert(_ insertion: PasteInsertion, into bundleID: String, row: inout Row) async -> InsertionReceipt? {
        guard frontmost == bundleID else {
            row = fail(row, "Another app took focus before typing")
            return nil
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardMarker, forType: .string)
        guard let receipt = try? await insertion.insert(sentence) else {
            row = fail(row, "Insertion reported a failure")
            return nil
        }
        row.clipboard = pasteboard.string(forType: .string) == clipboardMarker ? "yes" : "NO"
        return receipt
    }

    private static func fail(_ row: Row, _ why: String) -> Row {
        var row = row
        row.inserted = "not run"
        row.note = why
        return row
    }

    private static var frontmost: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    private static func bringToFront(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return await waitFor(8) { frontmost == bundleID }
    }

    private static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.2)
        }
        return condition()
    }

    private static func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func press(_ key: Int, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func focusedValue() -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func windowTitle(of bundleID: String) -> String? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
