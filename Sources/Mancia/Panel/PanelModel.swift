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
    enum Phase: Equatable { case idle, running, applied, error }
    enum Scope: Equatable { case selection, document }

    var phase: Phase = .idle
    var scope: Scope = .selection
    var hasSelection = true
    var selectionCharCount = 0
    /// True while the selection is still being captured after an instant show.
    /// The status line reads "Reading selection…" until this clears.
    var capturing = false
    var instruction = ""
    var runningTitle = ""
    var errorText = ""
    /// Iteration history: number of versions (original + one per applied
    /// result) and which version the document currently shows.
    var versionCount = 0
    var currentIndex = 0
    /// Bumped on every fresh session so the view can refocus the field.
    var sessionSeq = 0

    // Wired by EditCoordinator.
    var onPerform: ((EditAction) -> Void)?
    /// Navigate the document to versions[index].
    var onNavigate: ((Int) -> Void)?
    var onRetry: (() -> Void)?
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
        runningTitle = ""
        errorText = ""
        versionCount = 0
        currentIndex = 0
        sessionSeq &+= 1
    }

    /// Route the hero action. Runs `Improve` when the field is empty, otherwise
    /// the typed custom instruction — the single Enter/primary path.
    func runPrimary() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onPerform?(.improve)
        } else {
            onPerform?(.custom(trimmed))
        }
    }

    func submitInstruction() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPerform?(.custom(trimmed))
    }
}
