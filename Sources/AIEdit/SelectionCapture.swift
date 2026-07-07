import AppKit

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
/// ⌘C / ⌘A / ⌘V keystrokes. Requires Accessibility permission.
@MainActor
enum SelectionCapture {
    private enum KeyCode {
        static let a: CGKeyCode = 0
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
    }

    /// Capture the current selection from the frontmost app via ⌘C.
    static func captureSelection() async -> SelectionCaptureResult {
        let targetApp = NSWorkspace.shared.frontmostApplication
        let snapshot = PasteboardSnapshot.capture()
        let text = await copyCurrentSelection()
        snapshot.restore()
        return SelectionCaptureResult(text: text, targetApp: targetApp, snapshot: snapshot)
    }

    /// Select all in the target app, then capture the whole document via ⌘C.
    static func captureEntireDocument(from result: SelectionCaptureResult) async -> String? {
        result.targetApp?.activate()
        try? await Task.sleep(for: .milliseconds(120))
        postCommandKey(KeyCode.a)
        try? await Task.sleep(for: .milliseconds(60))
        let text = await copyCurrentSelection()
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
            postCommandKey(KeyCode.a)
            try? await Task.sleep(for: .milliseconds(40))
        }
        postCommandKey(KeyCode.v)
        try? await Task.sleep(for: .seconds(1))
        result.snapshot.restore()
    }

    // MARK: - Internals

    /// Post ⌘C and poll the pasteboard for a change (up to 600 ms).
    private static func copyCurrentSelection() async -> String? {
        let pb = NSPasteboard.general
        let startCount = pb.changeCount
        postCommandKey(KeyCode.c)
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

    private static func postCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
