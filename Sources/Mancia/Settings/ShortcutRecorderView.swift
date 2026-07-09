import SwiftUI
import AppKit
import KeyboardShortcuts

/// A native replacement for `KeyboardShortcuts.Recorder`.
///
/// The upstream recorder reads localized strings from the package's
/// `Bundle.module`. SwiftPM's generated accessor resolves that resource bundle
/// against `Bundle.main.bundleURL` — the `.app` root in a hand-assembled
/// bundle — but macOS forbids loose content beside `Contents/`, so a
/// code-signed release cannot ship the bundle there and the recorder
/// fatal-errors the instant Settings opens (the DMG "crash on Settings" bug).
/// This view drives KeyboardShortcuts through its public API only and formats
/// the shortcut with symbols we build ourselves, so `Bundle.module` is never
/// touched. See docs/ARCHITECTURE.md.
struct ShortcutRecorderView: View {
    let name: KeyboardShortcuts.Name

    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(label)
                    .frame(minWidth: 150)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press a shortcut, or Esc to cancel" : "Click to record a new shortcut")

            if shortcut != nil, !isRecording {
                Button { clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: name) }
        .onDisappear(perform: stop)
    }

    private var label: String {
        isRecording ? "Press shortcut…" : (Self.display(shortcut) ?? "Record Shortcut")
    }

    // MARK: - Recording

    private func toggle() { isRecording ? stop() : start() }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        // A local monitor only sees events for our key window (the Settings
        // window while recording), and returning nil swallows them so a
        // captured chord never leaks into a text field.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            self.handle(event)
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func clear() {
        KeyboardShortcuts.setShortcut(nil, for: name)
        shortcut = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Bare Escape cancels; Escape with modifiers is a legitimate shortcut.
        if event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            stop()
            return nil
        }
        if let candidate = KeyboardShortcuts.Shortcut(event: event), Self.isAcceptable(candidate) {
            KeyboardShortcuts.setShortcut(candidate, for: name)
            shortcut = candidate
            stop()
        }
        return nil
    }

    /// A global hotkey needs a real key plus at least one "hard" modifier, so a
    /// bare letter (or plain Shift+letter) can't hijack normal typing.
    static func isAcceptable(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        guard shortcut.key != nil else { return false }
        let required: NSEvent.ModifierFlags = [.command, .control, .option]
        return !shortcut.modifiers.intersection(required).isEmpty
    }

    // MARK: - Display

    /// Symbolic display of a shortcut (e.g. "⌃⌥⌘E"), built without
    /// KeyboardShortcuts' localized `description`, which pulls in `Bundle.module`.
    @MainActor
    static func display(_ shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut else { return nil }
        return modifierSymbols(shortcut.modifiers) + keyGlyph(for: shortcut)
    }

    @MainActor
    private static func keyGlyph(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        guard let equivalent = shortcut.nsMenuItemKeyEquivalent, !equivalent.isEmpty else { return "?" }
        if equivalent == " " { return "Space" }
        return equivalent.uppercased()
    }

    /// Canonical macOS order: ⌃⌥⇧⌘.
    static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }
}
