import AppKit
import ApplicationServices

/// Finds the text caret in the app that has focus, so the overlay can sit under it.
/// Uses the Accessibility permission Murmur already has. Many apps do not report a caret; the answer is then nil.
enum CaretLocator {
    /// The caret in AppKit screen coordinates (origin at the bottom left of the main display).
    static func caretRect() -> CGRect? {
        // Asked of the app in front, not system-wide: a timeout set on the system-wide element would shorten
        // every Accessibility call Murmur makes from then on, including the check that Undo relies on.
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        // An app that is slow to answer must not hold up the start of a take.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return flipped(rect, mainDisplayHeight: NSScreen.screens.first?.frame.height)
    }

    /// Accessibility measures from the top left of the main display; AppKit from its bottom left.
    /// Apps without a real caret tend to answer with an empty rectangle at the origin: that is no caret.
    nonisolated static func flipped(_ rect: CGRect, mainDisplayHeight: CGFloat?) -> CGRect? {
        guard let mainDisplayHeight, rect.height > 0, rect.height < 200, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
