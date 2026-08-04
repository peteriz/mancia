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
    enum Phase: Equatable { case idle, running, confirm, applied, error }
    enum Scope: Equatable { case selection, document }
    /// The ribbon's focusable cells. Action carries its stable catalog index;
    /// Run exists only inside the disclosed Custom field. None keeps a fresh
    /// ribbon visually neutral until the user chooses a control.
    enum Cell: Hashable { case none, action(Int), direction, run }
    /// The action described by the ribbon right now. Explicit selection keeps
    /// an empty Custom field distinct from the default Improve action.
    enum ActionChoice: Equatable { case preset(PanelPreset), custom }

    /// Custom follows the four presets in the default strip and owns ⌘5.
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
        }
    }
    var scope: Scope = .selection
    var hasSelection = true
    var selectionCharCount = 0
    /// True while the selection is still being captured after an instant show.
    /// The status line reads "Reading selection…" until this clears.
    var capturing = false
    var instruction = ""
    var actionChoice: ActionChoice = .preset(.improve)
    var runningTitle = ""
    var errorText = ""
    /// Size of the document and the pending result while awaiting confirmation
    /// of a whole-document replacement (`.confirm` phase).
    var pendingOriginalCharCount = 0
    var pendingResultCharCount = 0
    /// The pending result itself, so the review region can show what is about
    /// to overwrite the document. Cleared as soon as the decision is made —
    /// this is the user's text and there is no reason to hold it longer.
    var pendingResultPreview = ""
    /// Whether the review region's result preview and the error strip's detail
    /// are disclosed.
    ///
    /// View state that lives on the model on purpose: the ribbon is rendered by
    /// two hosting views — one on screen, one off screen that measures the
    /// height the window is sized to — and a `@State` flag would leave the two
    /// disagreeing about how tall the lane is.
    var previewExpanded = false
    var errorDetailsExpanded = false
    /// Iteration history: number of versions (original + one per applied
    /// result) and which version the document currently shows.
    var versionCount = 0
    var currentIndex = 0
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
    /// Restore the previous applied version. The instruction field gets first
    /// refusal on ⌘Z; this is the fallback once its own undo stack is empty.
    var onUndoVersion: (() -> Bool)?
    var onRetry: (() -> Void)?
    /// Apply the pending whole-document replacement awaiting confirmation.
    var onConfirmApply: (() -> Void)?
    /// Stop the in-flight action but keep the session open.
    var onCancelRun: (() -> Void)?
    /// Close the whole session (Esc / Done), keeping the document as shown.
    var onCancel: (() -> Void)?

    /// Esc means "back out of the smallest thing in progress".
    ///
    /// While an action is running that is the run itself, so the ribbon stays
    /// up and the user can try something else. With nothing in flight there is
    /// nothing smaller to leave than the session, so Esc dismisses the ribbon.
    func escape() {
        if phase == .running {
            onCancelRun?()
        } else {
            onCancel?()
        }
    }

    func reset(hasSelection: Bool, charCount: Int) {
        phase = .idle
        self.hasSelection = hasSelection
        selectionCharCount = charCount
        scope = hasSelection ? .selection : .document
        capturing = false
        instruction = ""
        actionChoice = .preset(.improve)
        runningTitle = ""
        errorText = ""
        pendingOriginalCharCount = 0
        pendingResultCharCount = 0
        pendingResultPreview = ""
        previewExpanded = false
        errorDetailsExpanded = false
        versionCount = 0
        currentIndex = 0
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
        self.scope = scope
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

    /// The Custom button and ⌘5 disclose its field without running it.
    func selectCustomInstruction() {
        guard !isLocked else { return }
        actionChoice = .custom
        returnFocusToPrimaryControl()
    }

    /// A visible action button or ⌘1…⌘5. Built-ins run immediately; Custom
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
    var isLocked: Bool { phase == .running || phase == .confirm }

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

    /// Tab / ⇧Tab, wrapping at both ends.
    func moveFocus(_ move: PanelKeyCommand.FocusMove) {
        let cells = focusableCells
        let step = move == .next ? 1 : cells.count - 1
        guard let current = cells.firstIndex(of: focusedCell) else {
            focusedCell = cells[0]
            return
        }
        focusedCell = cells[(current + step) % cells.count]
    }

    /// Every visible control is its own stop, in visual order. Direction
    /// replaces Custom while its field is disclosed.
    var focusableCells: [Cell] {
        var cells: [Cell] = []
        for index in actionDisplayOrder {
            if index == Self.customActionIndex, isCustomInstructionSelected {
                cells.append(.direction)
            } else {
                cells.append(.action(index))
            }
        }
        if isCustomInstructionSelected { cells.append(.run) }
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
        return actionProgressLabel(at: index)
    }

    /// Reserved beside the idle label so status changes never resize the strip.
    func actionProgressLabel(at index: Int) -> String? {
        if PanelPreset.all.indices.contains(index) {
            return PanelPreset.all[index].action.progressLabel
        }
        return index == Self.customActionIndex ? EditAction.custom("").progressLabel : nil
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
        Self.actionIndices.contains(index) ? "⌘\(index + 1)" : nil
    }

    var customSubmitTitle: String { phase == .running ? "Working" : "Run" }

    /// Ask the coordinator to walk the applied-version history backward.
    /// Kept on the model so the window's ⌘Z route stays independently testable.
    func undoLastVersion() -> Bool {
        guard phase == .applied, currentIndex > 0 else { return false }
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
        switch actionChoice {
        case .preset(let preset):
            onPerform?(preset.action, nil)
        case .custom:
            let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onPerform?(.custom(trimmed), nil)
        }
    }

    /// Return to the buttons-only default after an edit lands.
    func restoreDefaultAction() {
        instruction = ""
        actionChoice = .preset(.improve)
        focusedCell = .none
    }
}
