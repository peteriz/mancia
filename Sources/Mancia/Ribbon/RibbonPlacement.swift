import CoreGraphics

/// Where the command ribbon sits, resolved from screen and host-window
/// geometry. Pure and free of AppKit lookups so every branch is unit-testable;
/// `RibbonWindow` supplies a `Context` built from live `NSScreen` /
/// Accessibility values.
///
/// The rule the ribbon rests on:
///
/// > When the host reports where the selected text is, sit just under it —
/// > just over it if the selection is too near the foot of the host to fit
/// > beneath. When the selection is too tall for either end, sit in the margin
/// > beside it. Otherwise — a bare caret, or a host that cannot answer — take
/// > the predictable place: flush below the menu bar when the screen reserves
/// > a strip for it, or inset below the frontmost window's title bar when it
/// > does not.
///
/// The lane used to take the predictable place always, and drop to the *foot
/// of the host* when it would otherwise cover the selection. That cleared the
/// text but overshot: a selection near the top of a window sent the lane the
/// entire height of the screen away from the sentence it was invoked on, so
/// the user read the result nowhere near where they were looking. Sitting
/// against the selection clears the same text and moves as little as possible
/// doing it, and it puts the command the user is composing next to the words
/// it will rewrite.
///
/// A selection tall enough to leave no room at either end used to send the
/// lane back to that predictable place — the same overshoot in a new costume,
/// and worse, because the lane then landed *on* the head of the block it was
/// invoked on. A tall selection is usually a narrow one: a paragraph is a
/// column of text with a margin either side of it. So before retreating, the
/// rule looks along the selection's flanks, where a lane covers nothing at
/// all. Only a block with no room at its ends *and* no margin beside it — a
/// select-all in a maximized window, where every position covers the text
/// equally — falls back, and then it takes the roomier end anyway if the lane
/// can stand clear of the words there as it opens.
///
/// Whichever edge faces the selection is the edge the lane *pins*, so it grows
/// away from the text: a review gate opening under a lane that sits beneath
/// the text can never creep back over the line it was invoked on, and one
/// opening beside it grows along a margin it already owns. Which is also why
/// the room at the selection's ends is judged at `projectedHeight` rather than
/// the height the lane opens at.
///
/// Horizontal position is imposed by the host, not by the caret, at the three
/// anchors that hang over it — the lane never chases a caret sideways along a
/// line, and its controls stay where the hand expects them. A lane in the
/// margin is the one exception, and it is not chasing anything: it is the only
/// place left that the text does not already occupy.
///
/// One amendment after each apply: pasting can put words where the opening
/// geometry never described them — a longer result flows past the old
/// selection's foot, and hosts scroll to keep the caret visible. When the
/// lane is found covering the text it just wrote (`laneObstructs` against
/// `updatedTextRect`), the anchor is re-decided against where that text
/// actually is. A lane already clear of the words holds still: the user's
/// eye is on the result, and a move that buys no visibility is churn.
///
/// The predictable place is chosen by measurement rather than a capability
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
        /// The anchor the lane settled on when it opened, once it has opened.
        ///
        /// Placement is decided once and then held. The lane grows and shrinks
        /// while a request runs — a status word, a review gate, an expanded
        /// error — and each of those re-resolves the frame. Re-deciding the
        /// anchor every time would let a lane leap across the screen mid-run
        /// and leap back when the region closed. Feeding the established
        /// anchor back in pins the decision to the geometry that was true at
        /// open, which is the geometry the user saw.
        ///
        /// `RibbonWindow` clears it in exactly two places: when a fresh
        /// mid-session selection moves the work somewhere else, and when a
        /// landed paste leaves the lane covering the text it just wrote.
        var establishedAnchor: Anchor?

        init(
            screenFrame: CGRect,
            visibleFrame: CGRect,
            hostWindowFrame: CGRect? = nil,
            safeAreaTop: CGFloat = 0,
            menuBarHidden: Bool = false,
            selectionRect: CGRect? = nil,
            establishedAnchor: Anchor? = nil
        ) {
            self.screenFrame = screenFrame
            self.visibleFrame = visibleFrame
            self.hostWindowFrame = hostWindowFrame
            self.safeAreaTop = safeAreaTop
            self.menuBarHidden = menuBarHidden
            self.selectionRect = selectionRect
            self.establishedAnchor = establishedAnchor
        }
    }

    /// Which edge the lane hangs from. Drives the corner treatment and the
    /// direction it slides in from: a lane flush against an edge of the screen
    /// rounds only the two corners facing away from it, and a floating lane
    /// rounds all four.
    enum Anchor: Equatable {
        /// Flush under the menu bar.
        case screen
        /// Floating below the frontmost window's title bar.
        case hostWindow
        /// Floating just under the selected text.
        case belowSelection
        /// Floating just over it, when there was no room underneath.
        case aboveSelection
        /// In the margin to the left of the selection, when the block is too
        /// tall to sit at either end of.
        case leftOfSelection
        /// In the margin to its right, which is the roomier flank more often
        /// than not — text starts at the left of its column.
        case rightOfSelection

        /// The way the lane travels as it slides into place, as a unit vector
        /// in AppKit coordinates.
        ///
        /// Every anchor moves *away* from the edge it pins, so it emerges from
        /// behind whatever it hangs off: a lane hanging from the menu bar
        /// drops out from behind it, one sitting on top of the selection rises
        /// off the line it covers, and one in the margin slides out sideways
        /// from under the words rather than dropping past them.
        var entranceDirection: CGVector {
            switch self {
            case .screen, .hostWindow, .belowSelection: CGVector(dx: 0, dy: -1)
            case .aboveSelection: CGVector(dx: 0, dy: 1)
            case .leftOfSelection: CGVector(dx: -1, dy: 0)
            case .rightOfSelection: CGVector(dx: 1, dy: 0)
            }
        }
    }

    struct Resolution: Equatable {
        var frame: CGRect
        var anchor: Anchor
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

    /// Breathing room left between the lane's edge and the selection it sits
    /// against, so the two never touch. Applied on both axes: the lane sits
    /// against the flanks of a tall selection as readily as against its ends.
    static let selectionClearance: CGFloat = 8

    /// The least room an *end* of the selection has to offer before the lane
    /// will settle against it anyway — the last stop before the predictable
    /// place, taken only once no end can hold `projectedHeight` and no flank
    /// can hold the lane at all.
    ///
    /// It is one command row: the lane as it opens still stands clear of the
    /// words, and only a review gate reaches back over them — which, on a
    /// selection, means a run the user deliberately retargeted at the whole
    /// document. Staying against the text is worth that much, because the
    /// alternative covers the head of the same block from the far end of the
    /// screen.
    static let crampedRoom: CGFloat = 56

    /// The height every fit decision is taken against, whatever the lane
    /// currently measures.
    ///
    /// The lane opens as a single command row and grows later — a status word
    /// costs it nothing, but a review gate takes it to about 195pt, measured.
    /// Placement is decided at open, on a lane barely 50pt tall, and then held
    /// for the session. Judging the room at the selection's ends on that
    /// opening height would let the lane claim a gap it cannot actually fit
    /// into, and discover it only once a result arrived.
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
        // How far above the bottom of the host the lane may reach. A
        // screen-anchored lane measures against the visible frame, which
        // already excludes the Dock; a window-anchored one is floating over
        // its host, so it keeps the same inset it uses at the top.
        let floorClearance = menuBarReservesStrip ? 0 : revealClearance

        // The minimum wins over the maximum: a lane too narrow to lay out is a
        // worse failure than one wider than its host, which merely overhangs.
        let width = max(minimumWidth, min(host.width, maximumWidth))
        let x = host.minX + (host.width - width) / 2   // centered on the host

        // The band the lane is allowed to occupy.
        let ceiling = host.maxY - clearance
        let floor = host.minY + floorClearance
        let selection = avoidedSelection(in: context)
        let resting: Anchor = menuBarReservesStrip ? .screen : .hostWindow

        /// The margin between one flank of the selection and the edge of the
        /// host, measured — like the room at its ends — against the band the
        /// lane may occupy rather than against the selection's own window.
        func margin(_ side: Anchor) -> CGFloat? {
            guard let selection else { return nil }
            return side == .leftOfSelection
                ? selection.minX - host.minX
                : host.maxX - selection.maxX
        }

        /// A lane in the margin, or `nil` when that margin cannot hold one.
        ///
        /// It is the one anchor whose width is not the host's: it takes the
        /// widest lane the margin can hold, so it never reaches across the
        /// text it is standing beside. And it is the one anchor that grows
        /// symmetrically — the edge it pins is the vertical one facing the
        /// selection, and along a margin it owns outright there is nothing
        /// for the other axis to creep over.
        func marginFrame(_ side: Anchor, _ h: CGFloat) -> CGRect? {
            guard let selection, let margin = margin(side), margin >= minimumWidth else { return nil }
            let w = max(minimumWidth, min(margin, maximumWidth))
            let x = side == .leftOfSelection ? selection.minX - w : selection.maxX
            // Level with the middle of the block, which is where the eye is,
            // then held inside the band.
            let y = min(max(selection.midY - h / 2, floor), max(floor, ceiling - h))
            return CGRect(x: x, y: y, width: w, height: h)
        }

        /// Where an anchor puts a lane of a given height. Each pins the edge
        /// facing the selection, so the lane always grows away from what it
        /// sits against — a review region opening below the selection can
        /// never creep back over the line it was invoked on.
        func frame(_ anchor: Anchor, _ h: CGFloat) -> CGRect {
            let restingFrame = CGRect(x: x, y: ceiling - h, width: width, height: h)
            let rect: CGRect = switch anchor {
            case .screen, .hostWindow:
                restingFrame
            case .belowSelection:
                CGRect(x: x, y: (selection?.minY ?? ceiling) - h, width: width, height: h)
            case .aboveSelection:
                CGRect(x: x, y: selection?.maxY ?? floor, width: width, height: h)
            case .leftOfSelection, .rightOfSelection:
                marginFrame(anchor, h) ?? restingFrame
            }
            return clamp(rect, to: context.screenFrame)
        }

        func choose() -> Anchor {
            guard let selection else { return resting }
            // Judged at the lane's tallest ordinary state — see `projectedHeight`.
            let tall = max(height, projectedHeight)
            // A selection scrolled clean out of the band — behind the Dock,
            // above the menu bar — is not something to sit against.
            guard selection.minY <= ceiling, selection.maxY >= floor else { return resting }

            // Deliberately measured against the screen band, not the host
            // window, even though `host` is the window in the no-menu-bar case.
            // The lane is a floating overlay; it is not clipped to its host, and
            // a short window high on a large display has plenty of room beneath
            // it. Bounding the fit by the window would send the lane back to the
            // resting anchor at the top of the screen precisely when the
            // selection is near the window's foot — the long trek this rule
            // exists to remove. Spilling past a short host's bottom edge keeps
            // the lane 8pt from the words; retreating to the menu bar does not.
            let below = selection.minY - floor
            let above = ceiling - selection.maxY

            // Under the selection: the closest place to the text that is also
            // out of its way, and where growth heads away from it.
            if below >= tall { return .belowSelection }
            // Over it, when the selection sits too near the floor to fit beneath.
            if above >= tall { return .aboveSelection }

            // Neither end has room for a grown lane, which means the block is
            // tall — and a tall block is usually a narrow one. The margin
            // beside it costs the text nothing at all, so it beats both a
            // cramped end and the trek back to the top of the screen. The
            // roomier flank wins, so the lane is the least likely to be
            // squeezed below its natural width.
            let left = margin(.leftOfSelection) ?? 0
            let right = margin(.rightOfSelection) ?? 0
            if max(left, right) >= minimumWidth {
                return right >= left ? .rightOfSelection : .leftOfSelection
            }

            // No margin either: the block spans the host in both directions.
            // Sit at whichever end can still hold the lane as it opens — see
            // `crampedRoom` — rather than covering the head of the block from
            // the far end of the screen.
            if max(below, above) >= crampedRoom {
                return below >= above ? .belowSelection : .aboveSelection
            }

            // Nowhere at all: everything on screen is selected, and every
            // position covers it as thoroughly as the next. Predictability wins.
            return resting
        }

        let anchor = context.establishedAnchor ?? choose()
        return Resolution(frame: frame(anchor, height), anchor: anchor)
    }

    /// The span the applied text occupies once a paste has landed, judged
    /// from the two rectangles the session can still read: the selection the
    /// result replaced and the caret that now ends it. Pasting collapses the
    /// selection, so the caret is the only live report of where the new words
    /// stop — a longer result flows past the old selection's foot, and a host
    /// that scrolled to keep the caret visible moved everything with it. At
    /// open a bare caret is noise; here it is the tail of the words just
    /// written, so it counts.
    static func updatedTextRect(
        previousSelection: CGRect?, caretAfterApply: CGRect?
    ) -> CGRect? {
        let selection = previousSelection.flatMap { rect in
            rect.width > 0 && rect.height > 0 ? rect : nil
        }
        let caret = caretAfterApply.flatMap { rect -> CGRect? in
            guard rect.height > 0 else { return nil }
            // A caret reports zero width; give it one so the rect survives
            // the width check every selection rect goes through.
            return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
        }
        switch (selection, caret) {
        case (nil, nil): return nil
        case (let rect?, nil), (nil, let rect?): return rect
        case (let selection?, let caret?): return selection.union(caret)
        }
    }

    /// Whether a lane at `frame` covers the updated text — the only condition
    /// that reopens the anchor decision after an apply.
    static func laneObstructs(_ frame: CGRect, updatedText: CGRect?) -> Bool {
        guard let updatedText else { return false }
        return frame.intersects(updatedText)
    }

    /// A caret is not a selection. With nothing selected the target is the
    /// whole document, so there is no particular line to sit against, and
    /// following the caret on every invocation would be noise.
    ///
    /// The returned rect carries the clearance already, so callers can sit
    /// flush against its edges.
    private static func avoidedSelection(in context: Context) -> CGRect? {
        guard let rect = context.selectionRect, rect.width > 0, rect.height > 0 else { return nil }
        return rect.insetBy(dx: -selectionClearance, dy: -selectionClearance)
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
