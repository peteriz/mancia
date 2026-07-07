import Foundation
import Observation

/// Observable state shared between the panel view and the coordinator that
/// drives it. The coordinator wires the closures; the view calls them.
@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable { case input, running, result, error }
    enum Scope: Equatable { case selection, document }

    var phase: Phase = .input
    var scope: Scope = .selection
    var hasSelection = true
    var selectionCharCount = 0
    var instruction = ""
    var resultText = ""
    var errorText = ""

    // Wired by EditCoordinator.
    var onPerform: ((EditAction) -> Void)?
    var onApply: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    func reset(hasSelection: Bool, charCount: Int) {
        phase = .input
        self.hasSelection = hasSelection
        selectionCharCount = charCount
        scope = hasSelection ? .selection : .document
        instruction = ""
        resultText = ""
        errorText = ""
    }

    func submitInstruction() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPerform?(.custom(trimmed))
    }
}
