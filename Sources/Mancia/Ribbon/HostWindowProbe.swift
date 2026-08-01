import AppKit
import ApplicationServices

/// Reads the frontmost application's focused-window frame, so a full-screen
/// host can be anchored to rather than covered.
///
/// Accessibility-gated exactly like `SelectionCapture`, and returns `nil`
/// rather than throwing on any failure — placement must degrade to the screen,
/// never fail the session. `EditCoordinator.start()` already gates the whole
/// session behind `ensureAccessibility()`, so an untrusted process never gets
/// this far in practice; the check here is the cheap belt to that braces.
@MainActor
enum HostWindowProbe {
    /// What the probe could learn about the window the ribbon is opening over.
    struct HostWindow: Equatable {
        /// The window's frame in AppKit screen coordinates.
        var frame: CGRect
        /// The window owns a full-screen Space, so no menu bar is drawn over
        /// it. `NSScreen.visibleFrame` does not report this — it describes the
        /// menu-bar strip, which a notched display reserves either way.
        var isFullScreen: Bool
    }

    /// Upper bound on each Accessibility call. This runs synchronously on the
    /// main actor while the lane is being shown, so a hung or busy host app
    /// must not be able to hang Mancia with it.
    private static let messagingTimeout: Float = 0.1

    /// The frontmost app's focused window, in AppKit screen coordinates.
    static func frontmostWindow() -> HostWindow? {
        guard Permissions.isAccessibilityTrusted,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }

        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, messagingTimeout)

        guard let window = element(application, kAXFocusedWindowAttribute),
              let origin = point(window, kAXPositionAttribute),
              let size = size(window, kAXSizeAttribute),
              origin.x.isFinite, origin.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let frame = SelectionCapture.appKitRect(fromAX: CGRect(origin: origin, size: size))
        else { return nil }

        // Not exported as a constant by ApplicationServices; `AXFullScreen` is
        // the attribute AppKit sets on a window that owns a full-screen Space.
        return HostWindow(frame: frame, isFullScreen: flag(window, "AXFullScreen"))
    }

    // MARK: - Attribute reads

    private static func flag(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
