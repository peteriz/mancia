import AppKit
import ApplicationServices

/// Accessibility permission helpers. CGEvent posting (⌘C/⌘V) needs this grant.
@MainActor
enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user for Accessibility access (shows the system dialog once).
    @discardableResult
    static func requestAccessibility() -> Bool {
        // kAXTrustedCheckOptionPrompt is a non-Sendable global; use its literal value.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Open the Accessibility pane in System Settings.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
