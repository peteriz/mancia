import AppKit
import Foundation
import Testing
@testable import Mancia

@Suite("Selection text verification")
struct SelectionTextVerificationTests {
    @MainActor
    @Test("Delayed editor evidence is recovered without copying again")
    func delayedSelectionEvidence() async throws {
        let element = AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier)
        let initial = captureEvidence(element: nil, range: nil, value: nil)
        let complete = captureEvidence(element: element)
        var reads = 0
        var waits = 0
        let result = try await SelectionCapture.recoverSelectionEvidence(initial, read: {
            reads += 1
            return reads < 3 ? nil : complete
        }, wait: { waits += 1 })
        #expect(reads == 3)
        #expect(waits == 3)
        #expect(result.text == "draft")
        #expect(result.target?.hasVerifiedRangeIdentity == true)
        #expect(result.target?.capturedFieldValue == "draft")
    }

    @MainActor
    @Test("Complete selection evidence never waits or rereads the editor")
    func completeSelectionEvidenceIsImmediate() async throws {
        let element = AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier)
        let initial = captureEvidence(element: element)
        var calls = 0
        let result = try await SelectionCapture.recoverSelectionEvidence(initial, read: {
            calls += 1
            return nil
        }, wait: { calls += 1 })
        #expect(calls == 0)
        #expect(result.target?.hasVerifiedRangeIdentity == true)
    }

    @MainActor
    @Test("Unavailable editor evidence stops after a bounded number of retries")
    func selectionEvidenceRetriesAreBounded() async throws {
        let initial = captureEvidence(element: nil, range: nil, value: nil)
        var reads = 0
        let result = try await SelectionCapture.recoverSelectionEvidence(initial, read: {
            reads += 1
            return nil
        }, wait: {})
        #expect(reads == 6)
        #expect(result.text == initial.text)
        #expect(result.target?.hasVerifiedRangeIdentity == false)
        #expect(result.target?.capturedFieldValue == nil)
    }

    @MainActor
    @Test("Evidence recovery rejects changed windows, fields, ranges, and text")
    func selectionEvidenceRecoveryRejectsChangedTargets() async throws {
        let pid = NSRunningApplication.current.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        let other = AXUIElementCreateApplication(pid + 1)
        let initial = captureEvidence(element: element, window: element, value: nil)
        let changed = [
            captureEvidence(element: other, window: element),
            captureEvidence(element: element, window: other),
            captureEvidence(element: element, window: element, range: CFRange(location: 1, length: 5)),
            captureEvidence(element: element, window: element, text: "other"),
            SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: nil),
        ]
        for candidate in changed {
            let result = try await SelectionCapture.recoverSelectionEvidence(
                initial, read: { candidate }, wait: {})
            #expect(result.outcome == .uncertain(.targetChanged))
            #expect(result.target == nil)
        }
    }

    @MainActor
    @Test("Cancelling delayed evidence recovery prevents another editor read")
    func selectionEvidenceRecoveryRespectsCancellation() async {
        let initial = captureEvidence(element: nil, range: nil, value: nil)
        var reads = 0
        do {
            _ = try await SelectionCapture.recoverSelectionEvidence(initial, read: {
                reads += 1
                return nil
            }, wait: { throw CancellationError() })
            Issue.record("Cancelled recovery must throw")
        } catch is CancellationError {
            #expect(reads == 0)
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
    }

    @MainActor
    private func captureEvidence(
        element: AXUIElement?,
        window: AXUIElement? = nil,
        range: CFRange? = CFRange(location: 0, length: 5),
        value: String? = "draft",
        text: String = "draft"
    ) -> SelectionCaptureResult {
        let app = NSRunningApplication.current
        return SelectionCaptureResult(outcome: .selected(text), target: SelectionTargetEvidence(
            pid: app.processIdentifier,
            capturedBaseline: text,
            capturedFieldValue: value,
            scope: .selection,
            targetApp: app,
            window: window,
            focusedElement: element,
            selectedRange: range))
    }

    @Test("Rich-text representations verify without extending the saved range", arguments: [
        ("replacement", "replacement\n"),
        ("first  second", "first \u{00A0}second\n"),
        ("first  second", "first \u{00A0}second"),
        ("hello 😀 שלום", "hello 😀 שלום\n"),
        ("line\n", "line\n\n"),
    ])
    func richTextReplacement(pair: (String, String)) throws {
        let (replacement, actual) = pair
        let range = try #require(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: replacement,
            actualFieldValue: actual,
            replacing: CFRange(location: 0, length: 8),
            with: replacement,
            isRichTextField: true))
        #expect(range.location == 0)
        #expect(range.length == replacement.utf16.count)
    }

    @Test("Native fields still require exact text", arguments: [
        ("replacement", "replacement\n"),
        ("first  second", "first \u{00A0}second"),
    ])
    func nativeFieldsStayExact(pair: (String, String)) {
        let (replacement, actual) = pair
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: replacement,
            actualFieldValue: actual,
            replacing: CFRange(location: 0, length: 8),
            with: replacement,
            isRichTextField: false) == nil)
    }

    @Test("Exact replacement keeps UTF-16 offsets in native fields")
    func exactReplacementRange() throws {
        let prefix = "😀 before "
        let replacement = "שלום"
        let value = prefix + replacement + " after"
        let range = try #require(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: value,
            actualFieldValue: value,
            replacing: CFRange(location: prefix.utf16.count, length: 8),
            with: replacement,
            isRichTextField: false))
        #expect(range.location == prefix.utf16.count)
        #expect(range.length == replacement.utf16.count)
    }

    @Test("Rich-text space conversion preserves surrounding plain text")
    func surroundingPlainTextIsPreserved() throws {
        let replacement = "first  second"
        let expected = "before " + replacement + " after"
        let actual = "before first \u{00A0}second after"
        let range = try #require(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: expected,
            actualFieldValue: actual,
            replacing: CFRange(location: 7, length: 8),
            with: replacement,
            isRichTextField: true))
        #expect(range.location == 7)
        #expect(range.length == replacement.utf16.count)

        let reencodedContext = "before\u{00A0}first \u{00A0}second\u{00A0}after"
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: expected,
            actualFieldValue: reencodedContext,
            replacing: CFRange(location: 7, length: 8),
            with: replacement,
            isRichTextField: true) != nil)
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: expected,
            actualFieldValue: reencodedContext,
            replacing: CFRange(location: 7, length: 8),
            with: replacement,
            isRichTextField: false) == nil)
        for changed in [
            "Before first \u{00A0}second after",
            "before first \u{00A0}second After",
            "before  first \u{00A0}second after",
            "before\u{202F}first \u{00A0}second after",
            actual + "\n\n",
        ] {
            #expect(SelectionTextVerification.verifiedReplacementRange(
                expectedFieldValue: expected,
                actualFieldValue: changed,
                replacing: CFRange(location: 7, length: 8),
                with: replacement,
                isRichTextField: true) == nil)
        }
    }

    @Test("A new structural newline can follow unchanged surrounding text")
    func structuralNewlineAfterSuffix() throws {
        let expected = "before value after"
        let range = try #require(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: expected,
            actualFieldValue: expected + "\n",
            replacing: CFRange(location: 7, length: 8),
            with: "value",
            isRichTextField: true))
        #expect(range.location == 7)
        #expect(range.length == 5)
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: expected,
            actualFieldValue: expected + "\n",
            replacing: CFRange(location: 7, length: 8),
            with: "value",
            isRichTextField: false) == nil)
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: expected + "\n",
            actualFieldValue: expected + "\n\n",
            replacing: CFRange(location: 7, length: 8),
            with: "value",
            isRichTextField: true) == nil)
    }

    @Test("Verification does not trim text or collapse real blank lines", arguments: [
        ("replacement", "Replacement\n"),
        ("replacement", "replacement\n\n"),
        ("first\nsecond", "first\n\nsecond"),
        ("replacement\n", "replacement"),
        (" replacement ", "replacement"),
        ("replacement\t", "replacement "),
        ("replacement", "replacement\u{200B}"),
    ])
    func changedTextIsRejected(pair: (String, String)) {
        let (replacement, actual) = pair
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: replacement,
            actualFieldValue: actual,
            replacing: CFRange(location: 0, length: 8),
            with: replacement,
            isRichTextField: true) == nil)
    }

    @Test("Invalid replacement metadata cannot verify")
    func invalidRangesAreRejected() {
        for range in [
            CFRange(location: -1, length: 1),
            CFRange(location: 0, length: -1),
            CFRange(location: 20, length: 1),
            CFRange(location: 2, length: 1),
        ] {
            #expect(SelectionTextVerification.verifiedReplacementRange(
                expectedFieldValue: "text",
                actualFieldValue: "text",
                replacing: range,
                with: "text",
                isRichTextField: true) == nil)
        }
        #expect(SelectionTextVerification.verifiedReplacementRange(
            expectedFieldValue: "text",
            actualFieldValue: "text",
            replacing: CFRange(location: 0, length: 4),
            with: "",
            isRichTextField: true) == nil)
    }

    @Test("Rich-text Copy may encode AX non-breaking spaces as ordinary spaces")
    func selectedTextRepresentation() {
        #expect(SelectionTextVerification.matches(
            "first \u{00A0}second", "first  second", isRichTextField: true))
        #expect(!SelectionTextVerification.matches(
            "first \u{00A0}second", "first  second", isRichTextField: false))
        #expect(!SelectionTextVerification.matches(
            "first  second\n", "first  second", isRichTextField: true))
        #expect(!SelectionTextVerification.matches(
            "first  second", "first second", isRichTextField: true))
    }

    @Test("Select All can omit one structural newline in rich-text fields")
    func fullFieldSelection() {
        #expect(SelectionTextVerification.coversField(
            "text\n", range: CFRange(location: 0, length: 4),
            selectedText: "text", isRichTextField: true))
        #expect(SelectionTextVerification.coversField(
            "text\n", range: CFRange(location: 0, length: 5),
            selectedText: "text", isRichTextField: true))
        #expect(SelectionTextVerification.coversField(
            "text\n\n", range: CFRange(location: 0, length: 5),
            selectedText: "text\n", isRichTextField: true))
        #expect(SelectionTextVerification.coversField(
            "\n", range: CFRange(location: 0, length: 0),
            selectedText: "", isRichTextField: true))
        #expect(SelectionTextVerification.coversField(
            "\n", range: CFRange(location: 0, length: 1),
            selectedText: "", isRichTextField: true))
        #expect(SelectionTextVerification.coversField(
            "text", range: CFRange(location: 0, length: 4),
            selectedText: "text", isRichTextField: false))
        #expect(!SelectionTextVerification.coversField(
            "text\n", range: CFRange(location: 0, length: 4),
            selectedText: "text", isRichTextField: false))
        #expect(!SelectionTextVerification.coversField(
            "text\n", range: CFRange(location: 0, length: 5),
            selectedText: "text", isRichTextField: false))
        #expect(!SelectionTextVerification.coversField(
            "text\n\n", range: CFRange(location: 0, length: 4),
            selectedText: "text", isRichTextField: true))
        #expect(!SelectionTextVerification.coversField(
            "text\n", range: CFRange(location: 1, length: 4),
            selectedText: "text", isRichTextField: true))
        #expect(!SelectionTextVerification.coversField(
            "text\n", range: CFRange(location: 0, length: 4),
            selectedText: nil, isRichTextField: true))
    }
}
