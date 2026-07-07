import Foundation
import Observation

/// Observable state shared between the panel view and the coordinator that
/// drives it. The coordinator wires the closures; the view calls them.
///
/// The panel is a cyclical edit session: the describe field and action rows
/// are always visible, while a status strip cycles idle → running → applied
/// (Original | Rewritten toggle) → back, until the user closes the session.
@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable { case idle, running, applied, error }
    enum Scope: Equatable { case selection, document }
    /// Which version of the text is currently shown in the target document
    /// while the applied strip is up (session original vs latest result).
    enum Version: Equatable { case original, rewritten }

    var phase: Phase = .idle
    var scope: Scope = .selection
    var hasSelection = true
    var selectionCharCount = 0
    var instruction = ""
    var runningTitle = ""
    var errorText = ""
    var appliedVersion: Version = .rewritten

    // Wired by EditCoordinator.
    var onPerform: ((EditAction) -> Void)?
    var onSelectVersion: ((Version) -> Void)?
    var onRetry: (() -> Void)?
    /// Stop the in-flight action but keep the session open.
    var onCancelRun: (() -> Void)?
    /// Close the whole session (Esc / Done), keeping the document as shown.
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    func reset(hasSelection: Bool, charCount: Int) {
        phase = .idle
        self.hasSelection = hasSelection
        selectionCharCount = charCount
        scope = hasSelection ? .selection : .document
        instruction = ""
        runningTitle = ""
        errorText = ""
        appliedVersion = .rewritten
    }

    func submitInstruction() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPerform?(.custom(trimmed))
    }
}
