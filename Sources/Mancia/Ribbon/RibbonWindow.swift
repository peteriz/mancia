import AppKit
import SwiftUI

/// The command ribbon's window: a non-activating floating panel that hosts the
/// lane at the frame `RibbonPlacement` resolves for it.
///
/// Sizing runs the opposite way round from `EditPanel`. The panel sizes itself
/// to its content and then looks for somewhere to put it; the lane's **width is
/// imposed by placement** and only its **height comes from content**, so the
/// view is measured at the resolved width before the frame is set.
@MainActor
final class RibbonWindow {
    private let model: PanelModel
    private var panel: KeyablePanel?
    private var hosting: NSHostingView<RibbonView>?
    /// The host window's frame, captured once per `show()`. Deliberately not
    /// re-read on every reposition: the lane is transient, and chasing a
    /// dragged window would be worse than staying put.
    private var hostWindowFrame: CGRect?
    private var screenObserver: (any NSObjectProtocol)?
    /// Bumped on every `show()`, so an exit animation still in flight when a
    /// new session opens cannot order the new lane out.
    private var presentationSeq = 0

    /// Invoked on any key press routed to the lane. Returns whether the event
    /// was consumed (used to cancel the post-apply auto-close and to drive
    /// keyboard version navigation without the field swallowing the arrows).
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Invoked by ⌘, — the app has no menu bar to own this shortcut.
    var onOpenSettings: (() -> Void)?

    init(model: PanelModel) {
        self.model = model
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
        hostWindowFrame = HostWindowProbe.frontmostWindowFrame()
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
                panel.animator().setFrame(
                    resting.offsetBy(dx: 0, dy: resting.height), display: true)
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
        model.focusSeq &+= 1
    }

    /// Re-resolve and re-apply the frame. Called when the lane's height changes
    /// — the review region opening or closing — and when the screen
    /// configuration changes underneath it.
    ///
    /// The frame is anchored by its *top* edge, so a taller lane grows downward
    /// rather than shifting up.
    func reposition(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        let resolution = resolveFrame()
        guard resolution.frame != panel.frame else { return }
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.resize
                context.timingFunction = Motion.curve
                panel.animator().setFrame(resolution.frame, display: true)
            }
        } else {
            panel.setFrame(resolution.frame, display: true)
        }
        panel.invalidateShadow()
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
            // Start a lane's height above its home and slide down into it. The
            // lane sits below `.mainMenu`, so it genuinely emerges from behind
            // the menu bar rather than over it.
            panel.setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: false)
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
        RibbonView(model: model, width: width, anchor: anchor, isLive: false)
    }

    private func currentContext() -> RibbonPlacement.Context {
        guard let screen = targetScreen() else {
            return .init(screenFrame: .zero, visibleFrame: .zero)
        }
        return .init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hostWindowFrame: hostWindowFrame,
            safeAreaTop: screen.safeAreaInsets.top
        )
    }

    /// The screen holding the frontmost host window — deliberately not
    /// `NSScreen.main`, which is the screen with the key window and for a
    /// menu-bar app is regularly the wrong one.
    private func targetScreen() -> NSScreen? {
        if let host = hostWindowFrame {
            let overlapping = NSScreen.screens.max {
                overlap($0.frame, host) < overlap($1.frame, host)
            }
            if let overlapping, overlap(overlapping.frame, host) > 0 { return overlapping }
        }
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main
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
            rootView: content(width: RibbonPlacement.minimumWidth, anchor: .screen))
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
        // Unlike the panel, the lane has a computed home and must not be
        // draggable out of it.
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
        panel.onKeyDown = { [weak self] event in
            guard let self else { return false }
            // Tab is not a key equivalent, so it never reaches
            // `performKeyEquivalent`; the lane claims it here instead.
            if let move = PanelKeyCommand.focusMove(
                keyCode: event.keyCode, modifiers: event.modifierFlags)
            {
                model.moveFocus(move)
                return true
            }
            if onKeyDown?(event) == true { return true }
            // Return is the lane's primary key from every focus stop. The
            // Direction field answers its own through `onSubmit`, so it is
            // excluded here or the action would run twice.
            if PanelKeyCommand.isPrimaryReturn(
                keyCode: event.keyCode, modifiers: event.modifierFlags),
                model.focusedCell != .direction,
                model.phase != .running, model.phase != .confirm
            {
                model.runPrimary()
                return true
            }
            return false
        }
        panel.onTargetScope = { [weak self] scope in self?.model.setScope(scope) }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        panel.onSubmit = { [weak self] in
            guard let model = self?.model else { return }
            // Mirror the Return key: inert while a request runs or a
            // whole-document replacement awaits confirmation.
            guard model.phase != .running, model.phase != .confirm else { return }
            model.runPrimary()
        }
        return panel
    }
}
