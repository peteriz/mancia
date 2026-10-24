import AppKit
import SwiftUI
import Testing

@testable import Mancia

/// UI state coverage without using a real provider or the system pasteboard.
@MainActor
@Suite("Ribbon UI states")
struct RibbonUITests {

    // MARK: - Lock semantics

    @Test("Only scope-approval and running lock the ribbon")
    func lockedPhasesMatchIsLocked() {
        let model = PanelModel()
        let locked: Set<PanelModel.Phase> = [.scopeApproval, .running]
        for phase: PanelModel.Phase in [.idle, .scopeApproval, .running, .applied, .retained, .error] {
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

    @Test("Esc declines the scope-approval gate instead of closing")
    func escDeclinesGates() {
        let model = PanelModel()
        var declines = 0
        var cancels = 0
        model.onDeclinePending = { declines += 1 }
        model.onCancel = { cancels += 1 }

        model.phase = .scopeApproval
        model.escape()

        #expect(declines == 1)
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

    @Test("A fresh session clears result text and completion status")
    func resetClearsResultPresentation() {
        let model = PanelModel()
        model.retainedResult = "private result"
        model.appliedStatusText = "No changes needed"
        model.targetAppName = "Previous app"
        model.reset(hasSelection: false, charCount: 0)
        #expect(model.retainedResult.isEmpty)
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
        for phase: PanelModel.Phase in [.idle, .scopeApproval, .running, .applied, .retained, .error] {
            model.phase = phase
            #expect(model.focusableCells.contains(.target) == model.targetChipEnabled)
        }
    }

    // MARK: - Auto-refocus on phase and availability changes

    @Test("A phase change lands focus on the new phase's first cell when the old one no longer applies")
    func phaseChangeRefocusesAwayFromStaleCell() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)

        model.phase = .scopeApproval
        #expect(model.focusedCell == .scopeDecline)
        model.focusedCell = .scopeApprove

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

    // MARK: - Custom drawer

    @Test("Custom keeps its button in the row and opens its field after it")
    func customKeepsItsButtonAndAddsTheDrawer() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.selectCustomInstruction()

        #expect(model.focusableCells == [
            .action(0), .action(1), .action(2), .action(3), .action(4),
            .direction, .run, .target, .presetGroup,
        ])
        #expect(model.focusedCell == .direction)
    }

    @Test("Opening Custom never asks the lane for more width")
    func customDoesNotWidenTheLane() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        let context = RibbonPlacement.Context(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            preferredWidth: RibbonPlacement.standardWidth,
            minimumContentWidth: RibbonPlacement.standardWidth)
        let closed = RibbonPlacement.resolve(height: 44, in: context)
        model.selectCustomInstruction()
        let open = RibbonPlacement.resolve(height: 150, in: context)

        #expect(open.frame.width == closed.frame.width)
        #expect(open.frame.maxY == closed.frame.maxY, "the drawer grows the lane downward")
    }

    @Test("Above a selection, the drawer lifts the lane instead of covering the text")
    func drawerAboveSelectionGrowsUpward() {
        let selection = CGRect(x: 300, y: 120, width: 600, height: 40)
        let context = RibbonPlacement.Context(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            selectionRect: selection,
            establishedAnchor: .aboveSelection,
            preferredWidth: RibbonPlacement.standardWidth,
            minimumContentWidth: RibbonPlacement.standardWidth)
        let closed = RibbonPlacement.resolve(height: 44, in: context)
        let open = RibbonPlacement.resolve(height: 150, in: context)

        #expect(open.anchor == .aboveSelection)
        #expect(open.frame.minY == closed.frame.minY)
        #expect(open.frame.minY >= selection.maxY)
        #expect(!open.frame.intersects(selection))
    }

    @Test("A neutral ribbon stays neutral when a result lands")
    func appliedKeepsNeutralFocus() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.actionChoice = .preset(.sharpen)
        model.phase = .running
        #expect(model.focusedCell == .action(1))

        model.restoreButtonsAfterApply()
        model.phase = .applied
        #expect(model.focusedCell == .none, "no ring beside the lit action")

        model.moveFocus(.next)
        #expect(model.focusedCell == .action(0), "Tab still enters at the first cell")
    }

    // MARK: - Accent

    @Test("A fresh ribbon lights no action; a result lights the action that made it")
    func accentFollowsTheResult() {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        #expect(model.actionDisplayOrder.allSatisfy { !model.isActionHighlighted(at: $0) })

        model.actionChoice = .preset(.sharpen)
        model.phase = .running
        #expect(model.actionDisplayOrder.allSatisfy { !model.isActionHighlighted(at: $0) })

        model.appliedActionName = "Sharpen"
        model.phase = .applied
        #expect(model.actionDisplayOrder.filter { model.isActionHighlighted(at: $0) } == [1])

        model.actionChoice = .preset(.tighten)
        model.phase = .error
        #expect(model.actionDisplayOrder.filter { model.isActionHighlighted(at: $0) } == [3])

        model.phase = .idle
        model.selectCustomInstruction()
        #expect(model.actionDisplayOrder.filter { model.isActionHighlighted(at: $0) }
            == [PanelModel.customActionIndex])
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
            PanelModel.Phase.idle, .scopeApproval, .running, .applied, .retained, .error,
        ])
    func everyPhaseMeasuresANonZeroHeight(_ phase: PanelModel.Phase) {
        let model = PanelModel()
        model.reset(hasSelection: true, charCount: 12)
        model.onPerform = { _, _ in }
        model.onScopeChange = { _ in }
        model.onUndoVersion = { false }
        model.onRetry = {}
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
