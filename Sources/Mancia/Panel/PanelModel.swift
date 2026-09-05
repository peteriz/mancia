import AppKit
import Foundation
import Observation

/// Observable state shared between the panel view and the coordinator that
/// drives it. The coordinator wires the closures; the view calls them.
///
/// The ribbon is a cyclical edit session: its four preset controls stay visible
/// while Custom replaces its button with a field. A status
/// strip cycles idle → running → applied → back, until the user closes
/// the session. Applied versions remain available through ⌘Z.
@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable {
        case idle
        case scopeApproval
        case running
        case confirm
        case applied
        case retained
        case error
    }
    enum Scope: Equatable { case selection, document }
    /// The ribbon's focusable cells. Action carries its stable catalog index;
    /// Run exists only inside the disclosed Custom field. None keeps a fresh
    /// ribbon visually neutral until the user chooses a control.
    ///
    /// The gates and status rows each own their own cells so Tab can reach
    /// every visible, enabled control a phase discloses — the scope-approval
    /// and whole-document review gates, the applied/retained/error status
    /// rows — not just the command row. The target follows the actions in
    /// keyboard order, keeping the first Tab on the primary action.
    enum Cell: Hashable {
        case none
        case action(Int)
        case direction
        case run
        case target
        case scopeDecline
        case scopeApprove
        case reviewDisclosure
        case reviewDecline
        case reviewApprove
        case appliedUndo
        case retainedDisclosure
        case retainedCopy
        case errorDetails
        case errorCopy
        case errorRetry
    }
    /// The action described by the ribbon right now. Explicit selection keeps
    /// an empty Custom field distinct from the default Improve action.
    enum ActionChoice: Equatable { case preset(PanelPreset), custom }

    /// Custom follows the four presets in the default strip and owns shortcut 5.
    static let customActionIndex = PanelPreset.all.count
    static let actionIndices = Array(0...customActionIndex)

    var phase: Phase = .idle {
        didSet {
            // A new run invalidates whatever the last one disclosed: the old
            // result preview and the old failure's detail both belong to a
            // decision that has been superseded. Collapsing them here also
            // keeps the flags in step with the height the lane is resized to,
            // which is measured from a phase change.
            if phase == .running, oldValue != .running {
                previewExpanded = false
                errorDetailsExpanded = false
            }
            guard oldValue != phase else { return }
            if phase != .retained {
                retainedResultExpanded = false
            }
            // Every gate and status row lands with a safe default focus: the
            // first cell in its own list, which is never the destructive one
            // (decline precedes approve; disclosure precedes both). A cell
            // that survives the transition — the control actively running,
            // most often — keeps it instead of being bumped.
            if !focusableCells.contains(focusedCell) {
                focusedCell = focusableCells.first ?? .none
            }
        }
    }
    var scope: Scope = .selection
    var hasSelection = true
    var selectionCharCount = 0
    var targetAppName = ""
    /// True while the selection is still being captured after an instant show.
    /// The status line reads "Reading selection…" until this clears.
    var capturing = false
    var instruction = ""
    var actionChoice: ActionChoice = .preset(.improve)
    var runningTitle = ""
    var errorText = ""
    /// Describes a whole-document generation request without exposing or
    /// capturing the document text before the user approves it.
    var pendingScopeApprovalActionTitle = ""
    /// Size of the document and the pending result while awaiting confirmation
    /// of a whole-document replacement (`.confirm` phase).
    var pendingOriginalCharCount = 0
    var pendingResultCharCount = 0
    /// The pending result itself, so the review region can show what is about
    /// to overwrite the document. Cleared as soon as the decision is made —
    /// this is the user's text and there is no reason to hold it longer.
    var pendingResultPreview = ""
    /// The replacement baseline, cleared alongside the pending result.
    var pendingOriginalPreview = ""
    /// A generated result held for explicit copying rather than automatic paste.
    var retainedResult = ""
    var retainedReason = ""
    /// The action whose output was last verified as applied.
    var appliedActionName = ""
    /// Optional outcome copy for an applied-state result that did not create a
    /// new document version, such as "No changes needed".
    var appliedStatusText: String?
    /// Whether the review region's result preview and the error strip's detail
    /// are disclosed.
    ///
    /// View state that lives on the model on purpose: the ribbon is rendered by
    /// two hosting views — one on screen, one off screen that measures the
    /// height the window is sized to — and a `@State` flag would leave the two
    /// disagreeing about how tall the lane is.
    var previewExpanded = false
    var errorDetailsExpanded = false
    /// Bounded disclosure for the retained result, mirroring `previewExpanded`.
    /// Kept separate because a retained result and a pending review preview
    /// are never on screen at the same time, but each has to reset on its own
    /// phase's exit rather than the other's.
    var retainedResultExpanded = false
    /// Iteration history: number of versions (original + one per applied
    /// result) and which version the document currently shows.
    var versionCount = 0
    var currentIndex = 0
    /// The real navigation capability, not a guess based only on history count.
    var undoAvailable = false {
        didSet {
            // The Undo cell can disappear mid-`.applied` (the history runs
            // out) without a phase change to trigger the general refocus in
            // `phase`'s `didSet`, so it gets its own.
            guard oldValue != undoAvailable, !focusableCells.contains(focusedCell) else { return }
            focusedCell = focusableCells.first ?? .none
        }
    }
    /// Bumped on every fresh session so the view can refocus the primary control.
    var sessionSeq = 0
    /// Bumped whenever the panel retakes key status (e.g. after the Settings
    /// window closes) so the view restores the primary focus target.
    var focusSeq = 0
    /// Which cell holds keyboard focus.
    ///
    /// Lives on the model because Tab is not a key equivalent: it arrives at
    /// the window, which has no way to reach a view-local `@FocusState`. The
    /// view mirrors this into one, in both directions.
    var focusedCell: Cell = .none

    // Wired by EditCoordinator.
    /// Run an action, optionally with guidance the user typed alongside it.
    var onPerform: ((EditAction, String?) -> Void)?
    var onScopeChange: ((Scope) -> Void)?
    /// Restore the previous applied version. The instruction field gets first
    /// refusal on ⌘Z; this is the fallback once its own undo stack is empty.
    var onUndoVersion: (() -> Bool)?
    var onRetry: (() -> Void)?
    /// Apply the pending whole-document replacement awaiting confirmation.
    var onConfirmApply: (() -> Void)?
    /// Approve capturing and sending the whole document to the provider.
    var onApproveDocumentGeneration: (() -> Void)?
    /// Decline either approval gate without closing the session.
    var onDeclinePending: (() -> Void)?
    /// Explicit user copy of a blocked generated result.
    var onCopyRetainedResult: (() -> Void)?
    /// Stop the in-flight action but keep the session open.
    var onCancelRun: (() -> Void)?
    /// Close the whole session (Esc / Done), keeping the document as shown.
    var onCancel: (() -> Void)?

    /// Esc means "back out of the smallest thing in progress".
    ///
    /// While an action is running that is the run itself, so the ribbon stays
    /// up and the user can try something else. `.scopeApproval` and `.confirm`
    /// each have a coordinator-owned decline, which is the smallest thing to
    /// back out of in those phases. `.retained` has no such gate — the action
    /// already ran and was already blocked — so its own smallest pending thing
    /// is an open result disclosure, which Esc closes before it closes the
    /// session. With nothing smaller in progress there is nothing smaller to
    /// leave than the session, so Esc dismisses the ribbon.
    func escape() {
        if phase == .running {
            onCancelRun?()
        } else if phase == .scopeApproval || phase == .confirm {
            onDeclinePending?()
        } else if phase == .retained, retainedResultExpanded {
            retainedResultExpanded = false
        } else {
            onCancel?()
        }
    }

    func reset(hasSelection: Bool, charCount: Int) {
        phase = .idle
        self.hasSelection = hasSelection
        selectionCharCount = charCount
        targetAppName = ""
        scope = hasSelection ? .selection : .document
        capturing = false
        instruction = ""
        actionChoice = .preset(.improve)
        runningTitle = ""
        errorText = ""
        pendingScopeApprovalActionTitle = ""
        pendingOriginalCharCount = 0
        pendingResultCharCount = 0
        pendingResultPreview = ""
        pendingOriginalPreview = ""
        retainedResult = ""
        retainedReason = ""
        appliedActionName = ""
        appliedStatusText = nil
        previewExpanded = false
        errorDetailsExpanded = false
        retainedResultExpanded = false
        versionCount = 0
        currentIndex = 0
        undoAvailable = false
        focusedCell = .none
        sessionSeq &+= 1
    }

    /// ⌘T and the Target menu. Aiming at the selection is inert when there is
    /// no selection to aim at — and while the capture that will answer that
    /// question is still running, where `hasSelection` is only an optimistic
    /// guess and the coordinator overwrites `scope` the moment it lands. The
    /// Target chip reads "Reading…" and offers no menu in that window; the
    /// shortcut has to be just as inert, or it silently does nothing.
    func setScope(_ scope: Scope) {
        guard !isLocked, !capturing, scope == .document || hasSelection else { return }
        guard self.scope != scope else { return }
        self.scope = scope
        onScopeChange?(scope)
    }

    /// ⌘T. Inert without a selection, where there is nothing to swap between.
    func toggleScope() {
        setScope(scope == .selection ? .document : .selection)
    }

    /// Select a preset without running it. Kept separate from activation for
    /// state restoration and tests; visible action buttons use `activateAction`.
    func selectPreset(at index: Int) {
        guard !isLocked, PanelPreset.all.indices.contains(index) else { return }
        actionChoice = .preset(PanelPreset.all[index])
        returnFocusToPrimaryControl()
    }

    /// The Custom button and shortcut 5 disclose its field without running it.
    func selectCustomInstruction() {
        guard !isLocked else { return }
        actionChoice = .custom
        returnFocusToPrimaryControl()
    }

    /// A visible action button or 1…5. Built-ins run immediately; Custom
    /// replaces its button with the field and hands focus to it.
    func activateAction(at index: Int) {
        guard !isLocked else { return }
        if PanelPreset.keyboardActions.indices.contains(index) {
            let preset = PanelPreset.keyboardActions[index]
            actionChoice = .preset(preset)
            returnFocusToPrimaryControl()
            onPerform?(preset.action, nil)
        } else if index == Self.customActionIndex {
            selectCustomInstruction()
        }
    }

    /// Whether the command cells are taking input. The keyboard has to honor
    /// this itself: the shortcuts are resolved by the window, above the SwiftUI
    /// tree, so they never see the `disabled` that greys the cells out.
    var isLocked: Bool {
        phase == .scopeApproval || phase == .running || phase == .confirm
    }

    /// Whether the target chip accepts a click, ⌘T, or Return-while-focused
    /// right now. Locked phases already refuse `setScope`; a selection-less
    /// session refuses it too, because there is only one valid scope to be in
    /// and nothing to switch to.
    var targetChipEnabled: Bool {
        !isLocked && !capturing && hasSelection
    }

    /// Hand keyboard focus to the selected action, or to Custom's field.
    func returnFocusToPrimaryControl() {
        focusedCell = primaryFocusCell
        focusSeq &+= 1
    }

    var primaryFocusCell: Cell {
        switch actionChoice {
        case .preset(let preset):
            return .action(PanelPreset.all.firstIndex(of: preset) ?? 0)
        case .custom:
            return .direction
        }
    }

    /// The one cell still enabled while a request runs — the active action,
    /// which becomes a Cancel control rather than disappearing.
    private var runningFocusCell: Cell {
        switch actionChoice {
        case .preset(let preset):
            return .action(PanelPreset.all.firstIndex(of: preset) ?? 0)
        case .custom:
            return .run
        }
    }

    /// Tab / ⇧Tab, wrapping at both ends.
    func moveFocus(_ move: PanelKeyCommand.FocusMove) {
        let cells = focusableCells
        guard !cells.isEmpty else { return }
        let step = move == .next ? 1 : cells.count - 1
        guard let current = cells.firstIndex(of: focusedCell) else {
            focusedCell = cells[0]
            return
        }
        focusedCell = cells[(current + step) % cells.count]
    }

    /// Every visible, *enabled* control is its own Tab stop, in visual order —
    /// the command row's own cells, followed by whatever the current phase
    /// discloses below it. A locked phase (scope approval, a running action,
    /// the whole-document review gate) replaces the command row entirely,
    /// because every one of its cells is greyed out and inert while it holds.
    var focusableCells: [Cell] {
        switch phase {
        case .scopeApproval:
            return [.scopeDecline, .scopeApprove]
        case .confirm:
            return [.reviewDisclosure, .reviewDecline, .reviewApprove]
        case .running:
            return [runningFocusCell]
        case .idle, .applied, .retained, .error:
            var cells = commandRowCells
            switch phase {
            case .applied:
                if undoAvailable { cells.append(.appliedUndo) }
            case .retained:
                if !retainedResult.isEmpty {
                    cells.append(.retainedDisclosure)
                    cells.append(.retainedCopy)
                }
            case .error:
                cells.append(.errorDetails)
                cells.append(.errorCopy)
                cells.append(.errorRetry)
            default:
                break
            }
            return cells
        }
    }

    /// The command row's own cells, regardless of phase: the four built-ins
    /// and Custom, or Direction and its inline Run once Custom is disclosed.
    private var commandRowCells: [Cell] {
        var cells: [Cell] = []
        for index in actionDisplayOrder {
            if index == Self.customActionIndex, isCustomInstructionSelected {
                cells.append(.direction)
            } else {
                cells.append(.action(index))
            }
        }
        if isCustomInstructionSelected { cells.append(.run) }
        if targetChipEnabled { cells.append(.target) }
        return cells
    }

    /// Four built-ins then Custom, in the same order in every state.
    var actionDisplayOrder: [Int] {
        Self.actionIndices
    }

    func actionTitle(at index: Int) -> String? {
        if PanelPreset.all.indices.contains(index) { return PanelPreset.all[index].title }
        return index == Self.customActionIndex ? "Custom" : nil
    }

    func actionSymbol(at index: Int) -> String? {
        if PanelPreset.all.indices.contains(index) { return PanelPreset.all[index].action.symbol }
        return index == Self.customActionIndex ? EditAction.custom("").symbol : nil
    }

    /// The label shown on an action control in its current phase.
    func actionLabel(at index: Int) -> String? {
        guard let title = actionTitle(at: index) else { return nil }
        guard phase == .running, isActionSelected(at: index) else { return title }
        return runningStatus(at: index)
    }

    /// Reserved beside the idle label so status changes never resize the strip.
    func actionProgressLabel(at index: Int) -> String? {
        if PanelPreset.all.indices.contains(index) {
            return PanelPreset.all[index].action.progressLabel
        }
        return index == Self.customActionIndex ? EditAction.custom("").progressLabel : nil
    }

    /// The truthful label for the control actively running, at `index` or for
    /// Custom's inline Run control. Prefers the coordinator's live stage —
    /// "Reading document", "Applying", "Restoring version", and so on — over
    /// the static per-action progress label, so a whole-document generation's
    /// capture step never reads "Improving" while Mancia is still only reading
    /// the document. Falls back to the static label when the coordinator
    /// hasn't set one, which keeps this usable from tests that drive `phase`
    /// directly without a coordinator.
    func runningStatus(at index: Int) -> String {
        if capturing { return "Reading selection" }
        if !runningTitle.isEmpty { return runningTitle }
        return actionProgressLabel(at: index) ?? actionTitle(at: index) ?? ""
    }

    func isActionSelected(at index: Int) -> Bool {
        switch actionChoice {
        case .preset(let selected):
            return PanelPreset.all.indices.contains(index) && PanelPreset.all[index] == selected
        case .custom:
            return index == Self.customActionIndex
        }
    }

    /// True when the user has typed something to act on, as opposed to leaving
    /// the field empty and meaning "improve this".
    var hasCustomInstruction: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isCustomInstructionSelected: Bool {
        if case .custom = actionChoice { return true }
        return false
    }

    var canRunPrimary: Bool { !isCustomInstructionSelected || hasCustomInstruction }

    /// Custom is the only state that expands the ribbon. Every other phase uses
    /// one stable width so starting or finishing a request never moves the UI.
    var prefersExpandedRibbon: Bool {
        isCustomInstructionSelected
    }

    /// The visible keyboard hint for an action. Keeping this beside the action
    /// catalog guarantees hover labels and actual key routing stay in lockstep.
    func actionShortcut(at index: Int) -> String? {
        Self.actionIndices.contains(index) ? "\(index + 1)" : nil
    }

    /// A concise, one-line description of what an action does, for its hover
    /// tooltip. There is no separate copy catalog to keep in sync with —
    /// these mirror the wording `PanelPreset` and `EditAction` already
    /// document, so a tooltip and the action's real behavior cannot drift.
    func actionDescription(at index: Int) -> String? {
        if PanelPreset.all.indices.contains(index) {
            switch PanelPreset.all[index].action {
            case .improve: return "General proofread and rewrite"
            case .sharpen: return "Restructure text written for a coding agent"
            case .planFirst: return "Ask for a short plan with goals and verifiers"
            case .tighten: return "Compress without losing requirements"
            default: return nil
            }
        }
        return index == Self.customActionIndex ? "Describe your own edit" : nil
    }

    var customSubmitTitle: String {
        guard phase == .running else { return "Run" }
        return runningStatus(at: Self.customActionIndex)
    }

    /// Copies the current failure text to the system pasteboard. Self-contained
    /// (unlike `onCopyRetainedResult`) because there is nothing for the
    /// coordinator to do beyond what the model already holds, and both the
    /// error strip's Copy button and the window's Return-key routing need to
    /// reach it identically.
    func copyErrorToPasteboard() {
        guard !errorText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(errorText, forType: .string)
    }

    /// Ask the coordinator to walk the applied-version history backward.
    /// Kept on the model so the window's ⌘Z route stays independently testable.
    func undoLastVersion() -> Bool {
        guard phase == .applied, undoAvailable else { return false }
        return onUndoVersion?() ?? false
    }

    /// The action the primary control will run right now. Pure — no side
    /// effects, safe to read during layout.
    var resolvedActionTitle: String {
        switch actionChoice {
        case .preset(let preset): return preset.title
        case .custom: return "Custom"
        }
    }

    /// The icon for `resolvedActionTitle`, retained for status/help surfaces.
    var resolvedActionSymbol: String {
        switch actionChoice {
        case .preset(let preset): return preset.action.symbol
        case .custom: return EditAction.custom("").symbol
        }
    }

    /// The primary path, shared by Return and the field's run button. Runs a
    /// selected preset, or the disclosed custom instruction. Blank Custom is
    /// deliberately inert rather than silently falling back to Improve.
    func runPrimary() {
        guard !isLocked else { return }
        switch actionChoice {
        case .preset(let preset):
            onPerform?(preset.action, nil)
        case .custom:
            let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onPerform?(.custom(trimmed), nil)
        }
    }

    /// Return to the buttons-only default after an edit lands. A Custom draft
    /// survives for the rest of the session and is cleared by `reset`.
    func restoreButtonsAfterApply() {
        actionChoice = .preset(.improve)
        focusedCell = .none
    }
}
