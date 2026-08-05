import AppKit
import SwiftUI

/// The command ribbon's window: a non-activating floating panel that hosts the
/// lane at the frame `RibbonPlacement` resolves for it.
///
/// Sizing runs the opposite way round from a panel that opens beside the
/// caret. Such a panel sizes itself to its content and then looks for
/// somewhere to put it; the lane's **width is imposed by placement** and only
/// its **height comes from content**, so the view is measured at the resolved
/// width before the frame is set.
@MainActor
final class RibbonWindow: NSObject {
    private let model: PanelModel
    /// Read for the swoosh color at every rebuild, so a change made in
    /// Settings is in force the next time the lane opens.
    private let settings: AppSettings
    private var panel: KeyablePanel?
    private var hosting: NSHostingView<RibbonView>?
    /// What the Accessibility probe learned about the host window, captured
    /// once per `show()`. Deliberately not re-read on every reposition: the
    /// lane is transient, and chasing a dragged window would be worse than
    /// staying put.
    private var hostWindow: HostWindowProbe.HostWindow?
    /// The selection's bounds, read in `show()` — before the lane takes
    /// focus, after which the system-wide focused element is the Direction
    /// field and the rect would describe the lane itself. Replaced
    /// mid-session only on the coordinator's word, in the two moments the
    /// target app briefly owns focus again: a fresh selection captured for a
    /// new cycle, and a landed paste the lane was found covering.
    private var selectionRect: CGRect?
    /// The edge the lane currently hangs from, which decides both the side it
    /// slides in from and — fed back through `Context` — where it stays for
    /// the rest of the session. Cleared by `show()`.
    private var currentAnchor: RibbonPlacement.Anchor?
    private var screenObserver: (any NSObjectProtocol)?
    /// Bumped on every `show()`, so an exit animation still in flight when a
    /// new session opens cannot order the new lane out.
    private var presentationSeq = 0

    /// Invoked on any key press routed to the lane. Returns whether the event
    /// was consumed (used to cancel the post-apply auto-close and handle the
    /// lane's non-key-equivalent controls).
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Invoked by ⌘, — the app has no menu bar to own this shortcut.
    var onOpenSettings: (() -> Void)?

    init(model: PanelModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        super.init()
    }

    /// The lane's entrance: it slides down from behind the menu bar, which is
    /// where it lives. Faster out than in.
    private enum Motion {
        static let entrance: TimeInterval = 0.22
        static let exit: TimeInterval = 0.14
        static let resize: TimeInterval = 0.18
        static let fade: TimeInterval = 0.12
        static var curve: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }
    }

    // MARK: - Presentation

    func show() {
        presentationSeq &+= 1
        let panel = panel ?? makePanel()
        self.panel = panel
        hostWindow = HostWindowProbe.frontmostWindow()
        selectionRect = SelectionCapture.selectionScreenRect()
        currentAnchor = nil
        let resolution = resolveFrame()
        observeScreenChanges()
        present(panel, at: resolution.frame)
    }

    /// Dismiss the lane. While shown it stays visible permanently — synthetic
    /// keystrokes are posted to the target app's pid, so the lane never needs
    /// to get out of their way.
    func close() {
        guard let panel, panel.isVisible else { return }
        stopObservingScreenChanges()
        let token = presentationSeq
        let resting = panel.frame
        let reduced = reduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? Motion.fade : Motion.exit
            context.timingFunction = Motion.curve
            if !reduced {
                let offset = hiddenOffset(for: resting)
                panel.animator().setFrame(
                    resting.offsetBy(dx: offset.width, dy: offset.height), display: true)
            }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationSeq == token, let panel = self.panel else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrame(resting, display: false)
            }
        })
    }

    /// Retake key status after the target app was activated for a keystroke
    /// burst, so Esc (and typing) reach the lane again. No reordering, no
    /// flicker; no-op when the lane isn't on screen. Also puts focus back in
    /// the field — regaining key alone doesn't restore the first responder
    /// (e.g. after the Settings window closes).
    func focus() {
        guard let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        if model.focusedCell != .none { model.focusSeq &+= 1 }
    }

    /// Whether the lane still holds key status.
    ///
    /// The lane takes key without activating Mancia, so the host app stays
    /// the frontmost application throughout a session and losing key means
    /// something specific: the user clicked back into the host — in this app,
    /// almost always to select the next span. The post-apply auto-close beat
    /// reads this before it fires.
    var isKey: Bool { panel?.isKeyWindow ?? false }

    /// Re-resolve and re-apply the frame. Called when the lane's height changes
    /// — the review region opening or closing — and when the screen
    /// configuration changes underneath it.
    ///
    /// Each anchor pins the edge it hangs from, so the lane grows away from
    /// whatever it is sitting against rather than moving across it.
    func reposition(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        let previousWidth = panel.frame.width
        let resolution = resolveFrame()
        guard resolution.frame != panel.frame else { return }
        let widthChanged = abs(resolution.frame.width - previousWidth) > 0.5
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.resize
                context.timingFunction = Motion.curve
                panel.animator().setFrame(resolution.frame, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard widthChanged else { return }
                    self?.model.returnFocusToPrimaryControl()
                }
            })
        } else {
            panel.setFrame(resolution.frame, display: true)
            if widthChanged {
                model.returnFocusToPrimaryControl()
            }
        }
        panel.invalidateShadow()
    }

    /// A fresh selection captured mid-session: the user is now working
    /// somewhere the lane's opening geometry never described, so the anchor
    /// is re-decided against the new words — the same rule `show()` applies,
    /// taken again at the moment the target moved. `nil` (a host that cannot
    /// report bounds) changes nothing.
    func noteSelectionMoved(_ rect: CGRect?) {
        guard let panel, panel.isVisible, let rect, rect != selectionRect else { return }
        selectionRect = rect
        // The work moved, so re-read what it moved to. `show()`'s probe is
        // deliberately not refreshed per reposition — chasing a dragged window
        // would be worse than staying put — but a selection landing in another
        // window, or in another app on another display, changes which host and
        // which screen the lane has to be resolved against. A probe that
        // cannot answer leaves the last good host in place rather than
        // demoting the lane to the screen.
        if let host = HostWindowProbe.frontmostWindow() { hostWindow = host }
        currentAnchor = nil
        reposition()
    }

    /// The one post-apply exception to "decided once and then held": a paste
    /// can put words where the opening geometry never described them — a
    /// longer result flows past the old selection's foot, and hosts scroll to
    /// keep the caret visible. When the lane is found sitting on the text it
    /// just wrote, the anchor is re-decided against where that text actually
    /// is. A lane already clear of the words holds still: a move that buys no
    /// visibility is churn.
    func avoidUpdatedText(caretRect: CGRect?) {
        guard let panel, panel.isVisible else { return }
        let updated = RibbonPlacement.updatedTextRect(
            previousSelection: selectionRect, caretAfterApply: caretRect)
        guard RibbonPlacement.laneObstructs(panel.frame, updatedText: updated) else { return }
        selectionRect = updated
        currentAnchor = nil
        reposition()
    }

    private func present(_ panel: NSPanel, at frame: CGRect) {
        if reduceMotion {
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fade
                panel.animator().alphaValue = 1
            }
        } else {
            // Start a lane's height off its home edge and slide into it. The
            // lane sits below `.mainMenu`, so hanging from the menu bar it
            // genuinely emerges from behind the menu bar rather than over it;
            // sitting over the selection it rises from below instead, and
            // standing in the margin it slides out sideways.
            let offset = hiddenOffset(for: frame)
            panel.setFrame(frame.offsetBy(dx: offset.width, dy: offset.height), display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.entrance
                context.timingFunction = Motion.curve
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// How far off its home the lane starts and ends its slide. Each anchor
    /// enters from the edge it is pinned to: down from behind the menu bar or
    /// from under the selection it hangs beneath, up from over the selection
    /// it sits above, and sideways out from under a selection it sits beside.
    ///
    /// One travel distance for all of them, and it is the lane's *height* even
    /// on the horizontal anchors. Vertically that is the distance that hides
    /// the lane completely behind its edge; horizontally nothing is hiding it,
    /// so the same number reads as a short slide in the direction it settles —
    /// where its own width would be a 600pt lurch across the screen.
    private func hiddenOffset(for frame: CGRect) -> CGSize {
        let direction = (currentAnchor ?? .screen).entranceDirection
        return CGSize(width: -direction.dx * frame.height, height: -direction.dy * frame.height)
    }

    // MARK: - Placement

    /// Resolve the lane's frame in two passes: the width falls out of the
    /// screen and host geometry alone, so the view can be measured at that
    /// width and the real height fed back in. The measured content is then
    /// installed, so the live view always renders at the width it was sized
    /// for.
    private func resolveFrame() -> RibbonPlacement.Resolution {
        let context = currentContext()
        let widthProbe = RibbonPlacement.resolve(height: 0, in: context)
        let height = measuredHeight(width: widthProbe.frame.width, anchor: widthProbe.anchor)
        let resolution = RibbonPlacement.resolve(height: height, in: context)
        currentAnchor = resolution.anchor
        hosting?.rootView = content(width: resolution.frame.width, anchor: resolution.anchor)
        return resolution
    }

    /// Lay the lane out at `width` off screen and report the height it wants.
    ///
    /// A throwaway host each time, rather than one kept around and re-rooted.
    /// Two reasons, both learned the hard way: forcing layout on the *live*
    /// view trips AppKit's layer-tree re-entrancy assertion when a reposition
    /// lands during display, and a *reused* host answers `fittingSize` from
    /// the layout it last completed, so a height change measured in the same
    /// run-loop turn comes back as the height the lane is leaving. A fresh
    /// host has nothing to be stale about. It costs one view per height
    /// change, of which there are a handful per session.
    private func measuredHeight(width: CGFloat, anchor: RibbonPlacement.Anchor) -> CGFloat {
        let host = NSHostingView(rootView: measurementContent(width: width, anchor: anchor))
        host.safeAreaRegions = []
        return max(1, host.fittingSize.height)
    }

    private func content(width: CGFloat, anchor: RibbonPlacement.Anchor) -> RibbonView {
        RibbonView(
            model: model, width: width, anchor: anchor,
            swooshColor: Color(nsColor: settings.swooshColor),
            // Deferred a turn on purpose: the callback fires from inside
            // SwiftUI's update, and measuring before that update has settled
            // reports the height the lane is leaving, not the one it wants.
            onLayoutChange: { [weak self] in
                Task { @MainActor in self?.reposition() }
            })
    }

    /// The off-screen copy used only for sizing. It must not ask for a resize
    /// while it is being measured, or the measurement would recurse.
    private func measurementContent(
        width: CGFloat, anchor: RibbonPlacement.Anchor
    ) -> RibbonView {
        RibbonView(
            model: model, width: width, anchor: anchor,
            swooshColor: Color(nsColor: settings.swooshColor), isLive: false)
    }

    private func currentContext() -> RibbonPlacement.Context {
        guard let screen = targetScreen() else {
            return .init(screenFrame: .zero, visibleFrame: .zero)
        }
        let expanded = model.prefersExpandedRibbon
        return .init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hostWindowFrame: hostWindow?.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            menuBarHidden: menuBarHidden,
            selectionRect: selectionRect,
            establishedAnchor: currentAnchor,
            preferredWidth: expanded
                ? RibbonPlacement.expandedWidth
                : RibbonPlacement.standardWidth,
            minimumContentWidth: expanded
                ? RibbonPlacement.expandedWidth
                : RibbonPlacement.minimumWidth
        )
    }

    /// Is the host running without a menu bar over it? Two ways that happens,
    /// and neither is legible in `NSScreen` geometry on a notched display: the
    /// host owns a full-screen Space, or the menu bar is set to auto-hide.
    /// `_HIHideMenuBar` is the global-domain key behind Control Center's
    /// "Automatically hide and show the menu bar".
    private var menuBarHidden: Bool {
        if hostWindow?.isFullScreen == true { return true }
        return UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    }

    /// The screen holding the text being edited — deliberately not
    /// `NSScreen.main`, which is the screen with the key window and for a
    /// menu-bar app is regularly the wrong one.
    ///
    /// The selection leads, because it is what the lane is placed against: a
    /// window straddling two displays holds most of its area on one of them
    /// and the selected sentence can be on the other. The host window stands
    /// in when no selection rect came back — some hosts report none — and the
    /// pointer only when neither did, since it is wherever the hand left it
    /// rather than where the words are.
    private func targetScreen() -> NSScreen? {
        if let screen = screenOverlapping(selectionRect) { return screen }
        if let screen = screenOverlapping(hostWindow?.frame) { return screen }
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main
    }

    /// The screen a rectangle covers most of, or `nil` when it touches none.
    private func screenOverlapping(_ rect: CGRect?) -> NSScreen? {
        guard let rect else { return nil }
        let best = NSScreen.screens.max { overlap($0.frame, rect) < overlap($1.frame, rect) }
        guard let best, overlap(best.frame, rect) > 0 else { return nil }
        return best
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    // MARK: - Screen changes

    /// A display connected or disconnected, a resolution change, the Dock
    /// moved. Only observed while the lane is on screen.
    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition(animated: false) }
        }
    }

    private func stopObservingScreenChanges() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    // MARK: - Construction

    private func makePanel() -> KeyablePanel {
        let hosting = NSHostingView(
            rootView: content(width: RibbonPlacement.standardWidth, anchor: .screen))
        // The lane *is* the window: no title bar strip to sit below, and no
        // 28pt of transparent window above the ink. Without this the titled
        // panel's safe area pushes the content down and the lane stops
        // touching the menu bar.
        hosting.safeAreaRegions = []
        // The lane's height is placement's decision, not the hosting view's.
        // Left to itself NSHostingView resizes the window to fit its content,
        // which grows the lane *upward* from a fixed origin and races the
        // reposition that would have anchored it to the top edge.
        hosting.sizingOptions = []
        self.hosting = hosting

        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Placement is the lane's contract; dragging would detach it from the
        // selection or resting edge it was resolved against.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Deliberately not raised above `.mainMenu`: winning against the menu
        // bar would mean covering it in the windowed case, which is
        // user-hostile. `RibbonPlacement.revealClearance` is the correct fix.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window server draws this outside the frame, so the lane can stay
        // exactly the frame placement resolved. A SwiftUI shadow would be
        // clipped by the window bounds, and padding the window for one would
        // break that contract.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        // Without `.fullScreenAuxiliary` the hotkey would switch Spaces rather
        // than show the lane over a full-screen app.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.model.onCancel?() }
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onKeyDown = { [weak self] event in
            guard let self else { return false }
            // The coordinator sees every key first, because its first act is to
            // cancel the post-apply auto-close: a user reaching for any key is
            // still working, and the lane must not close underneath them. Tab
            // included — it used to be claimed above this and so kept the lane
            // on its 1.2-second fuse while the user was tabbing through it.
            if onKeyDown?(event) == true { return true }
            // Tab is not a key equivalent, so it never reaches
            // `performKeyEquivalent`; the lane claims it here instead.
            if let move = PanelKeyCommand.focusMove(
                keyCode: event.keyCode, modifiers: event.modifierFlags)
            {
                model.moveFocus(move)
                return true
            }
            // Return activates the focused action. Direction answers its own
            // through `onSubmit`, so it is excluded or Custom would run twice.
            if PanelKeyCommand.isPrimaryReturn(
                keyCode: event.keyCode, modifiers: event.modifierFlags),
                model.phase != .running, model.phase != .confirm
            {
                switch model.focusedCell {
                case .none:
                    return false
                case .action(let index):
                    model.activateAction(at: index)
                    return true
                case .run:
                    guard model.canRunPrimary else { return false }
                    model.runPrimary()
                    return true
                case .direction:
                    return false
                }
            }
            return false
        }
        panel.onToggleTarget = { [weak self] in self?.model.toggleScope() }
        panel.onActivateAction = { [weak self] index in self?.model.activateAction(at: index) }
        panel.onUndoVersion = { [weak self] in self?.model.undoLastVersion() ?? false }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        panel.onSubmit = { [weak self] in
            guard let model = self?.model else { return }
            // Mirror the Return key: inert while a request runs or a
            // whole-document replacement awaits confirmation.
            guard model.phase != .running, model.phase != .confirm, model.canRunPrimary else { return }
            model.runPrimary()
        }
        return panel
    }
}
