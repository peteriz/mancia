import Foundation

/// Pure approval policy for whole-document edits.
enum ApplyConfirmation {
    /// Document text must not be captured or sent to the provider until the
    /// user approves that scope. This gate is mandatory and independent of the
    /// replacement-confirmation setting.
    static func requiresGenerationApproval(isWholeDocument: Bool) -> Bool {
        isWholeDocument
    }

    /// A completed document replacement may have a second approval gate. This
    /// preserves the existing user setting without conflating it with consent
    /// to send the document to the provider.
    static func requiresReplacementApproval(
        isWholeDocument: Bool,
        userOptedIn: Bool
    ) -> Bool {
        isWholeDocument && userOptedIn
    }

    /// Compatibility spelling for the existing replacement policy.
    static func isRequired(isWholeDocument: Bool, userOptedIn: Bool) -> Bool {
        requiresReplacementApproval(
            isWholeDocument: isWholeDocument,
            userOptedIn: userOptedIn)
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
