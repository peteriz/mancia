import Foundation
import Observation

/// Observable state shared between the panel view and the coordinator that
/// drives it. The coordinator wires the closures; the view calls them.
///
/// The panel is a cyclical edit session: the describe field and action rows
/// are always visible (disabled while a request runs), while a status strip
/// cycles idle → running → applied (iteration navigation) → back, until the
/// user closes the session.
@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable { case idle, running, confirm, applied, error }
    enum Scope: Equatable { case selection, document }
    /// The ribbon's focusable cells, listed in Tab order.
    enum Cell: Hashable, CaseIterable { case target, action, direction, run }

    var phase: Phase = .idle
    var scope: Scope = .selection
    var hasSelection = true
    var selectionCharCount = 0
    /// True while the selection is still being captured after an instant show.
    /// The status line reads "Reading selection…" until this clears.
    var capturing = false
    var instruction = ""
    /// A preset the user pinned from the Action cell, which then runs instead
    /// of the instruction-derived action. `nil` — the default — means the
    /// action is derived from the Direction field, as it always has been.
    var pinnedPreset: PanelPreset?
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
    /// Bumped on every fresh session so the view can refocus the field.
    var sessionSeq = 0
    /// Bumped whenever the panel retakes key status (e.g. after the Settings
    /// window closes) so the view puts focus back in the field.
    var focusSeq = 0
    /// Which cell holds keyboard focus.
    ///
    /// Lives on the model because Tab is not a key equivalent: it arrives at
    /// the window, which has no way to reach a view-local `@FocusState`. The
    /// view mirrors this into one, in both directions.
    var focusedCell: Cell = .direction

    // Wired by EditCoordinator.
    /// Run an action, optionally with guidance the user typed alongside it.
    var onPerform: ((EditAction, String?) -> Void)?
    /// Navigate the document to versions[index].
    var onNavigate: ((Int) -> Void)?
    var onRetry: (() -> Void)?
    /// Apply the pending whole-document replacement awaiting confirmation.
    var onConfirmApply: (() -> Void)?
    /// Stop the in-flight action but keep the session open.
    var onCancelRun: (() -> Void)?
    /// Close the whole session (Esc / Done), keeping the document as shown.
    var onCancel: (() -> Void)?

    func reset(hasSelection: Bool, charCount: Int) {
        phase = .idle
        self.hasSelection = hasSelection
        selectionCharCount = charCount
        scope = hasSelection ? .selection : .document
        capturing = false
        instruction = ""
        pinnedPreset = nil
        runningTitle = ""
        errorText = ""
        pendingOriginalCharCount = 0
        pendingResultCharCount = 0
        pendingResultPreview = ""
        previewExpanded = false
        errorDetailsExpanded = false
        versionCount = 0
        currentIndex = 0
        focusedCell = .direction
        sessionSeq &+= 1
    }

    /// ⌘1 / ⌘2, and the Target menu. Aiming at the selection is inert when
    /// there is no selection to aim at.
    func setScope(_ scope: Scope) {
        guard scope == .document || hasSelection else { return }
        self.scope = scope
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

    /// Target drops out of the ring while it is a static label — there is no
    /// selection to choose, so there is nothing there to operate.
    var focusableCells: [Cell] {
        guard hasSelection, !capturing else { return Cell.allCases.filter { $0 != .target } }
        return Cell.allCases
    }

    /// True when the user has typed something to act on, as opposed to leaving
    /// the field empty and meaning "improve this".
    var hasCustomInstruction: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The action the primary control will run right now, as the ribbon's
    /// Action cell shows it. Pure — no side effects, safe to read during
    /// layout.
    var resolvedActionTitle: String {
        if let pinnedPreset { return pinnedPreset.title }
        return hasCustomInstruction ? "Your instruction" : EditAction.improve.title
    }

    /// The primary path, shared by Return and the field's run button. Runs a
    /// pinned preset if there is one; otherwise `Improve` when the field is
    /// empty and the typed instruction when it is not.
    func runPrimary() {
        if let pinnedPreset {
            runPreset(pinnedPreset)
            return
        }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onPerform?(.improve, nil)
        } else {
            onPerform?(.custom(trimmed), nil)
        }
    }

    /// Run a preset chosen from the field's dropdown. Anything typed in the
    /// field rides along as additional guidance for the preset's specialized
    /// prompt, rather than replacing it the way the primary path would.
    func runPreset(_ preset: PanelPreset) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        onPerform?(preset.action, trimmed.isEmpty ? nil : trimmed)
    }
}
