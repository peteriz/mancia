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
    /// Abbreviated because it shares the panel's one-line status strip with the
    /// Cancel and Replace actions.
    static func summary(originalCharacters: Int, resultCharacters: Int) -> String {
        "\(originalCharacters) → \(resultCharacters) chars"
    }

    /// The same size change, spelled out for the ribbon's review region, which
    /// has room for it. Grouped thousands, because here the number is being
    /// read as a magnitude rather than glanced at.
    ///
    /// Grouping is left to `IntegerFormatStyle` rather than hand-rolled, since
    /// the separator and the grouping size both vary by locale.
    ///
    /// The locale is a parameter so tests can pin one. Everything about the
    /// output varies with it — the separator, whether a four-digit number is
    /// grouped at all, and even the digits themselves, which are not `0`–`9` in
    /// every locale — so an assertion against the machine's locale is an
    /// assertion about the machine.
    static func detailedSummary(
        originalCharacters: Int, resultCharacters: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = IntegerFormatStyle<Int>.number.grouping(.automatic).locale(locale)
        return "\(originalCharacters.formatted(style)) → \(resultCharacters.formatted(style)) characters"
    }
}
