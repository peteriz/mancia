import Foundation

/// Policy for pausing a completed edit for explicit confirmation before it is
/// applied to the target document.
///
/// Only a whole-document replacement (⌘A then ⌘V) is gated: it overwrites the
/// entire document, so a bad or injection-influenced result there is high
/// blast-radius. A selection edit replaces only the text the user highlighted
/// and is trivially undone, so it stays immediate. The gate is pure and
/// side-effect free so the policy can be unit-tested away from the panel.
enum ApplyConfirmation {
    /// Whether a finished edit should stop in the confirm phase before applying.
    /// - Parameters:
    ///   - isWholeDocument: the result would replace the entire document.
    ///   - userOptedIn: the user has left whole-document confirmation enabled.
    static func isRequired(isWholeDocument: Bool, userOptedIn: Bool) -> Bool {
        isWholeDocument && userOptedIn
    }

    /// A one-line, human-readable summary of the pending replacement's size
    /// change, so the user has a signal (e.g. a document collapsing to a
    /// handful of characters) before overwriting everything.
    static func summary(originalCharacters: Int, resultCharacters: Int) -> String {
        "\(originalCharacters) → \(resultCharacters) characters"
    }
}
