import AppKit
import ApplicationServices

/// A snapshot of the general pasteboard, so we can restore the user's clipboard
/// after borrowing it for copy/paste.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        var stored: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            if !dict.isEmpty { stored.append(dict) }
        }
        return PasteboardSnapshot(items: stored)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let objects = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !objects.isEmpty { pb.writeObjects(objects) }
    }
}

/// The outcome of a selection capture.
struct SelectionCaptureResult {
    var text: String?
    var targetApp: NSRunningApplication?
    var snapshot: PasteboardSnapshot
}

/// Pasteboard-based selection capture and replacement, driven by synthetic
/// ⌘C / ⌘A / ⌘V / ⌘Z keystrokes. Requires Accessibility permission.
///
/// Keystrokes are posted directly to the target app's process with
/// `CGEvent.postToPid(_:)`, so they are delivered to that app regardless of
/// which window is key — the floating panel can stay visible throughout.
@MainActor
enum SelectionCapture {
    private enum KeyCode {
        static let a: CGKeyCode = 0
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
        static let z: CGKeyCode = 6
    }

    /// Capture the current selection from the frontmost app via ⌘C.
    static func captureSelection() async -> SelectionCaptureResult {
        let targetApp = NSWorkspace.shared.frontmostApplication
        let snapshot = PasteboardSnapshot.capture()
        let text = await copyCurrentSelection(pid: targetApp?.processIdentifier)
        snapshot.restore()
        return SelectionCaptureResult(text: text, targetApp: targetApp, snapshot: snapshot)
    }

    /// Select all in the target app, then capture the whole document via ⌘C.
    static func captureEntireDocument(from result: SelectionCaptureResult) async -> String? {
        result.targetApp?.activate()
        try? await Task.sleep(for: .milliseconds(120))
        postCommandKey(KeyCode.a, to: result)
        try? await Task.sleep(for: .milliseconds(60))
        let text = await copyCurrentSelection(pid: result.targetApp?.processIdentifier)
        result.snapshot.restore()
        return text
    }

    /// Replace the target's selection (or whole document) with `text`, then
    /// restore the user's original pasteboard.
    static func apply(text: String, to result: SelectionCaptureResult, entireDocument: Bool) async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        result.targetApp?.activate()
        try? await Task.sleep(for: .milliseconds(150))
        if entireDocument {
            postCommandKey(KeyCode.a, to: result)
            try? await Task.sleep(for: .milliseconds(40))
        }
        postCommandKey(KeyCode.v, to: result)
        try? await Task.sleep(for: .seconds(1))
        result.snapshot.restore()
    }

    /// Probe the target app for a live selection mid-session via ⌘C, without
    /// disturbing the session's pasteboard snapshot. Returns nil when nothing
    /// is selected (the pasteboard doesn't change on an empty ⌘C).
    static func captureFreshSelection(from result: SelectionCaptureResult) async -> String? {
        result.targetApp?.activate()
        try? await Task.sleep(for: .milliseconds(120))
        let snapshot = PasteboardSnapshot.capture()
        let text = await copyCurrentSelection(pid: result.targetApp?.processIdentifier)
        snapshot.restore()
        return text
    }

    /// Undo the last applied edit in the target app via a synthetic ⌘Z.
    /// In NSTextView-based apps this also restores the replaced selection.
    static func undo(in result: SelectionCaptureResult) async {
        result.targetApp?.activate()
        try? await Task.sleep(for: .milliseconds(150))
        postCommandKey(KeyCode.z, to: result)
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Screen rectangle (AppKit bottom-left-origin coordinates) of the focused
    /// element's selected text range / caret, via the Accessibility API.
    /// Returns nil when any step fails (caller falls back to the mouse).
    static func selectionScreenRect() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let element = focusedValue as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success, let rangeValue else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &axRect),
              axRect.origin.x.isFinite, axRect.origin.y.isFinite,
              axRect != .zero else { return nil }

        // AX coordinates have a top-left origin on the primary screen; AppKit
        // uses a bottom-left origin. Flip vertically against the primary screen.
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(
            x: axRect.origin.x,
            y: primary.frame.maxY - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    // MARK: - Internals

    /// Post ⌘C and poll the pasteboard for a change (up to 600 ms).
    private static func copyCurrentSelection(pid: pid_t?) async -> String? {
        let pb = NSPasteboard.general
        let startCount = pb.changeCount
        postCommandKey(KeyCode.c, toPid: pid)
        var elapsed = 0
        while elapsed < 600 {
            try? await Task.sleep(for: .milliseconds(30))
            elapsed += 30
            if pb.changeCount != startCount { break }
        }
        guard pb.changeCount != startCount else { return nil }
        let string = pb.string(forType: .string)
        return (string?.isEmpty == false) ? string : nil
    }

    private static func postCommandKey(_ keyCode: CGKeyCode, to result: SelectionCaptureResult) {
        postCommandKey(keyCode, toPid: result.targetApp?.processIdentifier)
    }

    /// Post a ⌘-keystroke directly to the target process's event queue
    /// (`postToPid`), so delivery does not depend on which window is key and
    /// the floating panel never swallows it. Falls back to the HID event tap
    /// when no target pid is known.
    private static func postCommandKey(_ keyCode: CGKeyCode, toPid pid: pid_t?, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        if let pid {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
