import Foundation

enum SelectionTextVerification {
    static func matches(
        _ accessibilityText: String,
        _ plainText: String,
        isRichTextField: Bool
    ) -> Bool {
        if accessibilityText == plainText { return true }
        guard isRichTextField else { return false }
        return accessibilityText.replacingOccurrences(of: "\u{00A0}", with: " ")
            == plainText.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func coversField(
        _ field: String,
        range: CFRange,
        selectedText: String?,
        isRichTextField: Bool
    ) -> Bool {
        guard range.location == 0, range.length >= 0, let selectedText else { return false }
        if range.length == field.utf16.count,
           matches(selectedText, field, isRichTextField: isRichTextField) {
            return true
        }
        // Web editors can expose a final paragraph newline that Select All omits.
        guard isRichTextField, field.hasSuffix("\n"),
              range.length == field.utf16.count
                || range.length == field.utf16.count - 1 else { return false }
        return matches(
            selectedText, String(field.dropLast()), isRichTextField: true)
    }

    static func verifiedReplacementRange(
        expectedFieldValue: String,
        actualFieldValue: String,
        replacing range: CFRange,
        with replacement: String,
        isRichTextField: Bool
    ) -> CFRange? {
        let expected = expectedFieldValue as NSString
        let actual = actualFieldValue as NSString
        let replacementLength = replacement.utf16.count
        guard !replacement.isEmpty, range.location >= 0, range.length >= 0,
              range.location <= expected.length,
              replacementLength <= expected.length - range.location else { return nil }

        let replacementRange = NSRange(location: range.location, length: replacementLength)
        guard expected.substring(with: replacementRange) == replacement else { return nil }
        let replacementEnd = range.location + replacementLength
        let hasStructuralNewline = isRichTextField
            && (replacementEnd == expected.length || !expectedFieldValue.hasSuffix("\n"))
            && actual.length - expected.length == 1
            && actualFieldValue.hasSuffix("\n")
        guard actual.length == expected.length || hasStructuralNewline else { return nil }

        // Rich editors also re-encode spaces beside the inserted span.
        // No other surrounding characters or whitespace may change.
        guard matches(
                actual.substring(to: range.location),
                expected.substring(to: range.location),
                isRichTextField: isRichTextField),
              matches(
                actual.substring(with: NSRange(
                    location: replacementEnd,
                    length: expected.length - replacementEnd)),
                expected.substring(from: replacementEnd),
                isRichTextField: isRichTextField),
              matches(
                actual.substring(with: replacementRange),
                replacement,
                isRichTextField: isRichTextField) else { return nil }

        return CFRange(location: range.location, length: replacementLength)
    }
}
