import CoreGraphics

/// Where the command ribbon sits, resolved from screen and host-window
/// geometry. Pure and free of AppKit lookups so every branch is unit-testable;
/// `RibbonWindow` supplies a `Context` built from live `NSScreen` /
/// Accessibility values.
///
/// The rule the ribbon rests on:
///
/// > If the frontmost window's screen reserves no menu-bar strip, anchor to
/// > the host window's top edge, inset below the reveal area. Otherwise anchor
/// > to the screen, directly below the menu bar. Either way, if that would
/// > cover the text the user selected, park at the foot of the host instead.
///
/// That last clause corrects a rule this direction shipped with. The original
/// held that a window's position never affects placement, on the grounds that
/// the band under the menu bar belongs to the host's title bar. The arithmetic
/// does not support it: a title bar is 28pt and the lane is 56pt, growing to
/// ~91pt once the review region opens, so a lane hanging from the menu bar
/// covers 28–63pt of *content* in any window sitting flush below the menu bar
/// — which is where a great many windows sit, including a new TextEdit
/// document. Rather than let the lane bury the sentence it was invoked on, it
/// moves out of the way.
///
/// The primary detection signal is a measurement rather than a capability
/// query: `screenFrame.maxY - visibleFrame.maxY`. `visibleFrame` excludes the
/// menu bar at the top and the Dock at the bottom or sides, so the *top* gap
/// isolates the menu-bar strip.
///
/// On a notched display that measurement is not enough on its own. There the
/// top strip is permanently unavailable to ordinary windows, so `visibleFrame`
/// stops short of `frame` whether or not a menu bar is drawn — measured on a
/// 14" MacBook Pro, the gap is 33pt with the menu bar shown, 32pt with it
/// auto-hidden, and still 33pt while another app owns a full-screen Space.
/// Geometry alone therefore cannot separate the two states, so `menuBarHidden`
/// carries the answer explicitly; see `RibbonWindow.currentContext()`.
enum RibbonPlacement {
    /// Everything the rule needs, all injectable.
    struct Context: Equatable {
        /// The full frame of the screen holding the frontmost window.
        var screenFrame: CGRect
        /// That screen's visible frame (menu bar and Dock excluded).
        var visibleFrame: CGRect
        /// The frontmost window's frame in AppKit screen coordinates, when the
        /// Accessibility probe resolved one. `nil` falls back to the screen.
        var hostWindowFrame: CGRect?
        /// The screen's top safe-area inset — non-zero on notched displays.
        var safeAreaTop: CGFloat
        /// `true` when no menu bar is drawn over the host: the frontmost window
        /// owns a full-screen Space, or the menu bar is set to auto-hide. It
        /// overrides the measured gap, which a notched display leaves ambiguous.
        var menuBarHidden: Bool
        /// The selected text's bounds in AppKit screen coordinates, as captured
        /// *before* the lane took focus. `nil` for a caret with no selection,
        /// for a host that cannot report bounds, and once the lane itself owns
        /// the focused element — which is why `RibbonWindow` snapshots it in
        /// `show()` rather than re-reading it per resolution.
        var selectionRect: CGRect?
        /// Keeps a lane that has already parked at the foot of its host there
        /// for the rest of the session. The review region opening can push the
        /// lane's underside past a selection it previously cleared; without
        /// this the lane would leap the height of the screen mid-run, and leap
        /// back when the region closed.
        var preferBottom: Bool

        init(
            screenFrame: CGRect,
            visibleFrame: CGRect,
            hostWindowFrame: CGRect? = nil,
            safeAreaTop: CGFloat = 0,
            menuBarHidden: Bool = false,
            selectionRect: CGRect? = nil,
            preferBottom: Bool = false
        ) {
            self.screenFrame = screenFrame
            self.visibleFrame = visibleFrame
            self.hostWindowFrame = hostWindowFrame
            self.safeAreaTop = safeAreaTop
            self.menuBarHidden = menuBarHidden
            self.selectionRect = selectionRect
            self.preferBottom = preferBottom
        }
    }

    /// Which edge the lane hangs from. Drives the corner treatment: a lane
    /// flush against the top of the screen rounds only its bottom corners, one
    /// flush against the bottom rounds only its top corners, and a
    /// window-anchored lane floats and rounds all four.
    enum Anchor: Equatable { case screen, screenBottom, hostWindow }

    struct Resolution: Equatable {
        var frame: CGRect
        var anchor: Anchor
        /// Whether the lane moved to the foot of its host to clear the
        /// selection. `RibbonWindow` feeds this back as `preferBottom` and
        /// reverses the entrance and exit slide.
        var parked: Bool = false
    }

    /// Minimum clearance left above a window-anchored lane so the auto-revealing
    /// menu bar cannot slide over it. The lane stays at `.floating` (level 3)
    /// and the menu bar is `.mainMenu` (level 24), so the inset — not the window
    /// level — is what keeps the lane reachable.
    static let revealClearance: CGFloat = 28

    /// Never let the lane get narrower than this; below it the row's controls
    /// cannot hold their labels. Measured rather than guessed: at rest the two
    /// menus, the field at its minimum and Run come to a little over 500pt, and
    /// a running lane adds a Cancel and a status word on top of that.
    static let minimumWidth: CGFloat = 600

    /// …and never let it get wider than this. On a 5K or ultrawide display a
    /// full-width lane is thousands of points of mostly empty ink with `Run` a
    /// long way from the Direction field the user just typed in. Capping and
    /// centering keeps the command sentence readable as a sentence, and the
    /// lane is still top-centered, so it still opens in one predictable place.
    ///
    /// Once the cell captions went and every control sized to its content, a
    /// 1200pt lane was mostly gap — and the only cell able to absorb it was the
    /// Direction field, which is precisely the one that should not be a third
    /// of the screen wide.
    static let maximumWidth: CGFloat = 900

    /// Breathing room left between the lane's edge and the selection it is
    /// dodging, so a cleared selection does not sit flush against the lane.
    static let selectionClearance: CGFloat = 8

    /// The height the park decision is made against, whatever the lane
    /// currently measures.
    ///
    /// The lane opens as a single command row and grows later — a status word
    /// costs it nothing, but a review gate takes it to about 195pt, measured.
    /// The decision to park is taken once, at open, and then held for the
    /// session, so taking it against the resting height would let a lane that
    /// cleared the selection at open bury it the moment a result came back.
    /// Deciding against the tallest ordinary state instead means the lane
    /// commits early and stays put, which is the whole reason the choice is
    /// sticky.
    static let projectedHeight: CGFloat = 200

    static func resolve(height: CGFloat, in context: Context) -> Resolution {
        let topGap = context.screenFrame.maxY - context.visibleFrame.maxY
        let menuBarReservesStrip = topGap > 1 && !context.menuBarHidden

        let host = menuBarReservesStrip
            ? context.visibleFrame
            : (context.hostWindowFrame ?? context.screenFrame)

        let clearance = menuBarReservesStrip
            ? 0
            : max(revealClearance, context.safeAreaTop + 4)
        // A screen-anchored lane parks flush on the visible frame's floor,
        // which already excludes the Dock. A window-anchored one is floating
        // over its host, so it keeps the same inset it uses at the top.
        let footClearance = menuBarReservesStrip ? 0 : revealClearance

        // The minimum wins over the maximum: a lane too narrow to lay out is a
        // worse failure than one wider than its host, which merely overhangs.
        let width = max(minimumWidth, min(host.width, maximumWidth))
        let x = host.minX + (host.width - width) / 2   // centered on the host

        let top = clamp(
            CGRect(x: x, y: host.maxY - clearance - height, width: width, height: height),
            to: context.screenFrame)
        let foot = clamp(
            CGRect(x: x, y: host.minY + footClearance, width: width, height: height),
            to: context.screenFrame)

        // Decided against the lane's tallest ordinary state, not the height it
        // happens to be right now — see `projectedHeight`.
        let tall = max(height, projectedHeight)
        let parked = shouldPark(
            top: clamp(
                CGRect(x: x, y: host.maxY - clearance - tall, width: width, height: tall),
                to: context.screenFrame),
            foot: clamp(
                CGRect(x: x, y: host.minY + footClearance, width: width, height: tall),
                to: context.screenFrame),
            in: context)
        let anchor: Anchor = menuBarReservesStrip
            ? (parked ? .screenBottom : .screen)
            : .hostWindow
        return Resolution(frame: parked ? foot : top, anchor: anchor, parked: parked)
    }

    /// The lane gives up its resting place only when staying would cover the
    /// selection *and* moving would not. A selection tall enough to be hit at
    /// both ends of the screen — a whole-screen host with everything selected
    /// — leaves nowhere to hide, and there the predictable position is worth
    /// more than a move that buys nothing.
    private static func shouldPark(top: CGRect, foot: CGRect, in context: Context) -> Bool {
        if context.preferBottom { return true }
        guard let selection = avoidedSelection(in: context) else { return false }
        return top.intersects(selection) && !foot.intersects(selection)
    }

    /// A caret is not a selection. With nothing selected the target is the
    /// whole document, so there is no particular line the lane must keep
    /// visible, and parking on every invocation with the caret near the top of
    /// a window would be noise.
    private static func avoidedSelection(in context: Context) -> CGRect? {
        guard let rect = context.selectionRect, rect.width > 0, rect.height > 0 else { return nil }
        return rect.insetBy(dx: 0, dy: -selectionClearance)
    }

    /// Keep the lane on the display. Both axes clamp against the *screen*
    /// frame, not the visible frame: a full-screen host legitimately spans past
    /// `visibleFrame` horizontally when the Dock is on a side, and a
    /// window-anchored lane sits above `visibleFrame.maxY` by design.
    ///
    /// The lower bound is applied last on each axis so it wins outright. That
    /// only matters when the lane is larger than the display, and there the
    /// controls the user needs — the review region's buttons — sit at the
    /// lane's bottom edge, so overflowing off the top is the survivable failure
    /// and dropping off the bottom is not.
    private static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var result = frame
        result.origin.x = max(min(result.minX, screen.maxX - result.width), screen.minX)
        result.origin.y = max(min(result.minY, screen.maxY - result.height), screen.minY)
        return result
    }
}
