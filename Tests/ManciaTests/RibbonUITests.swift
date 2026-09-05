import AppKit
import SwiftUI
import Testing

@testable import Mancia

/// UI state coverage without using a real provider or the system pasteboard.
@MainActor
@Suite("Ribbon UI states")
struct RibbonUITests {

    // MARK: - Lock semantics

    @Test("Only scope-approval, running, and confirm lock the ribbon")
    func lockedPhasesMatchIsLocked() {
        let model = PanelModel()
        let locked: Set<PanelModel.Phase> = [.scopeApproval, .running, .confirm]
        for phase: PanelModel.Phase in [.idle, .scopeApproval, .running, .confirm, .applied, .retained, .error] {
            model.phase = phase
            #expect(model.isLocked == locked.contains(phase))
        }
    }

    @Test("A locked ribbon refuses presets, Custom, scope changes, and Run")
    func lockedRibbonIsInert() {
        let model = PanelModel()
        var performed = 0
        var scopeChanges = 0
        model.onPerform = { _, _ in performed += 1 }
        model.onScopeChange = { _ in scopeChanges += 1 }
        model.reset(hasSelection: true, charCount: 10)
        model.phase = .scopeApproval

        model.selectPreset(at: 1)
        model.selectCustomInstruction()
        model.setScope(.document)
        model.activateAction(at: 0)
        model.runPrimary()

        #expect(performed == 0)
        #expect(scopeChanges == 0)
        #expect(model.actionChoice == .preset(.improve))
        #expect(model.scope == .selection)
    }

    // MARK: - Esc routing

    @Test("Esc declines the scope-approval and confirm gates instead of closing")
    func escDeclinesGates() {
        let model = PanelModel()
        var declines = 0
        var cancels = 0
        model.onDeclinePending = { declines += 1 }
        model.onCancel = { cancels += 1 }

        model.phase = .scopeApproval
        model.escape()
        model.phase = .confirm
        model.escape()

        #expect(declines == 2)
        #expect(cancels == 0)
    }

    @Test("Esc closes the session from idle, applied, retained, and error alike")
    func escClosesFromRestingPhases() {
        let model = PanelModel()
        var cancels = 0
        model.onCancel = { cancels += 1 }

        for phase: PanelModel.Phase in [.idle, .applied, .retained, .error] {
            model.phase = phase
            model.escape()
        }

        #expect(cancels == 4)
    }

    // MARK: - Per-phase focusable cells

    @Test("Scope approval offers only decline and approve as Tab stops")
    func scopeApprovalFocusableCells() {
        let model = PanelModel()
        model.phase = .scopeApproval
        #expect(model.focusableCells == [.scopeDecline, .scopeApprove])
    }

    @Test("Confirm offers disclosure, decline, and approve as Tab stops")
    func confirmFocusableCells() {
        let model = PanelModel()
        model.phase = .confirm
        #expect(model.focusableCells == [.reviewDisclosure, .reviewDecline, .reviewApprove])
    }

    @Test("The review decline path uses the pending-decision callback")
    func reviewDeclineUsesPendingCallback() {
        let model = PanelModel()
        var declines = 0
        var runCancels = 0
        model.onDeclinePending = { declines += 1 }
        model.onCancelRun = { runCancels += 1 }
        model.phase = .confirm

        model.escape()

        #expect(declines == 1)
        #expect(runCancels == 0)
    }

    @Test("Applied adds Undo only while a version is available to undo")
    func appliedFocusableCellsGateOnUndoAvailable() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.phase = .applied

        #expect(!model.focusableCells.contains(.appliedUndo))

        model.undoAvailable = true
        #expect(model.focusableCells.contains(.appliedUndo))
        #expect(model.focusableCells.last == .appliedUndo)

        model.undoAvailable = false
        #expect(!model.focusableCells.contains(.appliedUndo))
    }

    @Test("A no-change applied outcome has no fake Undo history")
    func noChangeAppliedOutcomeDoesNotOfferUndo() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.appliedStatusText = "No changes needed"
        model.phase = .applied

        #expect(model.appliedStatusText == "No changes needed")
        #expect(model.undoAvailable == false)
        #expect(!model.focusableCells.contains(.appliedUndo))
    }

    @Test("A fresh session clears comparison text and completion status")
    func resetClearsResultPresentation() {
        let model = PanelModel()
        model.pendingOriginalPreview = "private original"
        model.pendingResultPreview = "private result"
        model.appliedStatusText = "No changes needed"
        model.targetAppName = "Previous app"
        model.reset(hasSelection: false, charCount: 0)
        #expect(model.pendingOriginalPreview.isEmpty)
        #expect(model.pendingResultPreview.isEmpty)
        #expect(model.appliedStatusText == nil)
        #expect(model.targetAppName.isEmpty)
    }

    @Test("Retained offers Copy and Disclosure only when there is a result")
    func retainedFocusableCellsGateOnResultText() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.phase = .retained

        model.retainedResult = ""
        #expect(!model.focusableCells.contains(.retainedDisclosure))
        #expect(!model.focusableCells.contains(.retainedCopy))

        model.retainedResult = "a generated paragraph"
        #expect(model.focusableCells.contains(.retainedDisclosure))
        #expect(model.focusableCells.contains(.retainedCopy))
    }

    @Test("Error always offers Details, Copy, and Retry as Tab stops")
    func errorFocusableCellsAreUnconditional() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.phase = .error
        #expect(model.focusableCells.contains(.errorDetails))
        #expect(model.focusableCells.contains(.errorCopy))
        #expect(model.focusableCells.contains(.errorRetry))
    }

    @Test("The target chip is a Tab stop exactly when it is enabled")
    func targetCellFollowsAvailability() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.undoAvailable = true
        model.retainedResult = "text"
        for phase: PanelModel.Phase in [.idle, .scopeApproval, .running, .confirm, .applied, .retained, .error] {
            model.phase = phase
            #expect(model.focusableCells.contains(.target) == model.targetChipEnabled)
        }
    }

    // MARK: - Auto-refocus on phase and availability changes

    @Test("A phase change lands focus on the new phase's first cell when the old one no longer applies")
    func phaseChangeRefocusesAwayFromStaleCell() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)

        model.phase = .confirm
        #expect(model.focusedCell == .reviewDisclosure)
        model.focusedCell = .reviewApprove

        model.phase = .idle
        #expect(model.focusedCell == .action(0))
    }

    @Test("Undo disappearing mid-applied refocuses even without a phase change")
    func undoAvailableRefocusesWithoutPhaseChange() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.phase = .applied
        model.undoAvailable = true
        model.focusedCell = .appliedUndo

        model.undoAvailable = false

        #expect(model.focusedCell == .action(0))
    }

    @Test("Retained's disclosure flag resets when the phase moves on")
    func retainedResultExpandedResetsOnPhaseExit() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.phase = .retained
        model.retainedResultExpanded = true

        model.phase = .applied

        #expect(model.retainedResultExpanded == false)
    }

    @Test("Custom uses a bounded flexible width below the old screen-wide layout")
    func customWidthIsBoundedAndFlexible() {
        #expect(RibbonPlacement.customMinimumWidth < RibbonPlacement.expandedWidth)
        #expect(RibbonPlacement.expandedWidth < 897)

        let context = RibbonPlacement.Context(
            screenFrame: CGRect(x: 0, y: 0, width: 740, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 740, height: 860),
            preferredWidth: RibbonPlacement.expandedWidth,
            minimumContentWidth: RibbonPlacement.customMinimumWidth)
        let resolution = RibbonPlacement.resolve(height: 80, in: context)

        #expect(resolution.frame.width == 740)
    }

    // MARK: - Rendering smoke test

    /// Off-screen `fittingSize` measurement, the same technique
    /// `RibbonWindow` itself uses to size the live lane — no window or
    /// `NSApplication` event loop required. This is a genuine rendering
    /// smoke test (catches a phase that fails to lay out at all) rather than
    /// a duplicate of the model-level phase tests above; it deliberately
    /// checks only for a sane positive height, not for specific subviews or
    /// identifiers, since the view side of these phases is still being wired
    /// up concurrently.
    @Test(
        "Every phase measures to a positive, finite height off-screen",
        arguments: [
            PanelModel.Phase.idle, .scopeApproval, .running, .confirm, .applied, .retained, .error,
        ])
    func everyPhaseMeasuresANonZeroHeight(_ phase: PanelModel.Phase) {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.onPerform = { _, _ in }
        model.onScopeChange = { _ in }
        model.onUndoVersion = { false }
        model.onRetry = {}
        model.onConfirmApply = {}
        model.onApproveDocumentGeneration = {}
        model.onDeclinePending = {}
        model.onCopyRetainedResult = {}
        model.onCancelRun = {}
        model.onCancel = {}
        model.phase = phase

        let host = NSHostingView(
            rootView: RibbonView(model: model, width: 320, anchor: .screen, isLive: false))
        host.safeAreaRegions = []
        let size = host.fittingSize

        #expect(size.height > 0)
        #expect(size.height.isFinite)
    }
}
