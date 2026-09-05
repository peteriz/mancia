import AppKit
import ApplicationServices

/// A complete pasteboard value used both for restoration and ownership checks.
struct PasteboardSnapshot: Equatable {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item in
            let values = Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
            return values.isEmpty ? nil : values
        }
        return PasteboardSnapshot(items: items)
    }

    @discardableResult
    func restore(
        to pasteboard: NSPasteboard = .general,
        ifOwnedBy ownership: PasteboardOwnership
    ) -> Bool {
        guard ownership.matches(
            changeCount: pasteboard.changeCount,
            contents: .capture(from: pasteboard)
        ) else { return false }

        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let objects = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(objects)
    }
}

/// The exact pasteboard state an operation wrote. Both the generation and the
/// value must still match before Mancia restores what preceded it.
struct PasteboardOwnership: Equatable {
    let changeCount: Int
    let contents: PasteboardSnapshot

    func matches(changeCount: Int, contents: PasteboardSnapshot) -> Bool {
        self.changeCount == changeCount && self.contents == contents
    }

    static func claim(_ pasteboard: NSPasteboard) -> PasteboardOwnership {
        PasteboardOwnership(
            changeCount: pasteboard.changeCount,
            contents: .capture(from: pasteboard)
        )
    }

    static func claimCopiedSelection(
        expectedSelectedText: String?,
        from pasteboard: NSPasteboard
    ) -> PasteboardOwnership? {
        guard let expectedSelectedText, !expectedSelectedText.isEmpty else { return nil }
        guard pasteboard.string(forType: .string) == expectedSelectedText else { return nil }
        return claim(pasteboard)
    }
}

enum SelectionCaptureFailure: Error, Equatable, LocalizedError {
    case noTargetApplication
    case targetTerminated
    case targetNotFrontmost
    case accessibilityPermissionRevoked
    case targetChanged
    case keyEventCreationFailed
    case copyTimedOut
    case copiedContentIsNotText

    var errorDescription: String? {
        switch self {
        case .noTargetApplication:
            "There is no application to edit."
        case .targetTerminated:
            "The application being edited is no longer running."
        case .targetNotFrontmost:
            "The application or field being edited is no longer active."
        case .accessibilityPermissionRevoked:
            "Mancia no longer has Accessibility permission."
        case .targetChanged:
            "The focused window or text field changed while Mancia was reading it."
        case .keyEventCreationFailed:
            "Mancia could not create the keyboard event needed to read the selection."
        case .copyTimedOut:
            "The application did not finish copying the selected text."
        case .copiedContentIsNotText:
            "The selected content is not plain text."
        }
    }
}

enum SelectionReadOutcome: Equatable {
    case selected(String)
    case noSelection
    case uncertain(SelectionCaptureFailure)
    case failed(SelectionCaptureFailure)
}

/// Evidence tying captured text to one process, window, field, and range.
///
/// Accessibility identity is optional because capture can still report useful
/// copy results for apps with incomplete AX support. Apply refuses to modify a
/// target unless the field and range can be verified.
struct SelectionTargetEvidence {
    enum Scope: Equatable {
        case selection
        case entireDocument
    }

    let pid: pid_t
    let capturedBaseline: String?
    let capturedFieldValue: String?
    let scope: Scope
    let targetApp: NSRunningApplication
    let window: AXUIElement?
    let focusedElement: AXUIElement?
    let selectedRange: CFRange?

    var hasVerifiedRangeIdentity: Bool {
        focusedElement != nil && selectedRange != nil
    }

    /// Stable for AX objects that compare equal, for bridging into pure session
    /// state without putting an AX object in that state.
    var elementIdentifier: UInt64? {
        focusedElement.map { UInt64(CFHash($0)) }
    }
}

struct SelectionCaptureResult {
    let outcome: SelectionReadOutcome
    let target: SelectionTargetEvidence?

    var text: String? {
        guard case .selected(let text) = outcome else { return nil }
        return text
    }

    var targetApp: NSRunningApplication? { target?.targetApp }
}

enum SelectionRetentionReason: Equatable, LocalizedError {
    case emptyReplacement
    case missingBaseline
    case unverifiedTarget
    case targetChanged
    case selectedRangeChanged
    case baselineChanged
    case pasteboardChanged

    var errorDescription: String? {
        switch self {
        case .emptyReplacement:
            "Mancia kept the existing text because the replacement was empty."
        case .missingBaseline:
            "Mancia kept the existing text because it had no captured baseline."
        case .unverifiedTarget:
            "Mancia kept the existing text because the original field and range could not be verified."
        case .targetChanged:
            "Mancia kept the existing text because the focused window or field changed."
        case .selectedRangeChanged:
            "Mancia kept the existing text because the selected range changed."
        case .baselineChanged:
            "Mancia kept the existing text because the target text changed."
        case .pasteboardChanged:
            "Mancia kept the existing text because another copy replaced its temporary pasteboard value."
        }
    }
}

enum SelectionApplyFailure: Equatable, LocalizedError {
    case targetTerminated
    case targetNotFrontmost
    case accessibilityPermissionRevoked
    case rangeReselectionFailed
    case keyEventCreationFailed
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .targetTerminated:
            "The application being edited is no longer running."
        case .targetNotFrontmost:
            "The application being edited is no longer active."
        case .accessibilityPermissionRevoked:
            "Mancia no longer has Accessibility permission."
        case .rangeReselectionFailed:
            "Mancia could not reselect the captured text range."
        case .keyEventCreationFailed:
            "Mancia could not create the keyboard event needed to apply the edit."
        case .unexpected(let message):
            message
        }
    }
}

/// Applying commits when ⌘V is posted. Cancellation before that point is safe;
/// cancellation after it still returns `.applied` after pasteboard cleanup.
enum SelectionApplyOutcome {
    case applied(target: SelectionTargetEvidence, pasteboardRestored: Bool)
    case retained(SelectionRetentionReason)
    case cancelled
    case failure(SelectionApplyFailure)
}

enum SelectionReselectionOutcome {
    case reselected(SelectionTargetEvidence)
    case retained(SelectionRetentionReason)
    case failure(SelectionApplyFailure)
}

/// Pasteboard-based selection capture and verified replacement. Every
/// pasteboard borrow owns its own snapshot; session creation never retains a
/// snapshot that could overwrite a later user copy.
@MainActor
enum SelectionCapture {
    private enum KeyCode {
        static let a: CGKeyCode = 0
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
    }

    private struct AXFocus {
        let window: AXUIElement?
        let element: AXUIElement?
        let range: CFRange?
    }

    private enum CopyResult {
        case selected(text: String, focus: AXFocus?)
        case noSelection(focus: AXFocus?)
        case uncertain(SelectionCaptureFailure)
        case failed(SelectionCaptureFailure)
    }

    private enum Validation {
        case valid(AXFocus)
        case retained(SelectionRetentionReason)
        case failed(SelectionApplyFailure)
    }

    /// Capture the current selection from the frontmost app via ⌘C.
    static func captureSelection(
        pasteboard: NSPasteboard = .general
    ) async throws -> SelectionCaptureResult {
        try Task.checkCancellation()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return SelectionCaptureResult(outcome: .failed(.noTargetApplication), target: nil)
        }
        return try await captureSelection(in: app, pasteboard: pasteboard)
    }

    /// Capture the current selection in the existing target app. A selection
    /// in another field becomes new evidence instead of inheriting the old
    /// field merely because its text happens to match.
    static func captureFreshSelection(
        from result: SelectionCaptureResult,
        pasteboard: NSPasteboard = .general
    ) async throws -> SelectionCaptureResult {
        guard let target = result.target else {
            return SelectionCaptureResult(outcome: .failed(.noTargetApplication), target: nil)
        }
        if let failure = targetFailure(target) {
            return SelectionCaptureResult(outcome: .failed(failure), target: target)
        }
        _ = target.targetApp.activate()
        try await wait(milliseconds: 120)
        guard isFrontmost(target) else {
            return SelectionCaptureResult(outcome: .failed(.targetNotFrontmost), target: target)
        }
        return try await captureSelection(in: target.targetApp, pasteboard: pasteboard)
    }

    /// Select all and capture a document only when the same AX window and field
    /// that supplied the session target still own focus. The original range is
    /// restored with AX even if cancellation interrupts the copy.
    static func captureEntireDocument(
        from result: SelectionCaptureResult,
        pasteboard: NSPasteboard = .general
    ) async throws -> SelectionCaptureResult {
        guard let target = result.target else {
            return SelectionCaptureResult(outcome: .failed(.noTargetApplication), target: nil)
        }
        if let failure = targetFailure(target) {
            return SelectionCaptureResult(outcome: .failed(failure), target: target)
        }
        guard isFrontmost(target) else {
            return SelectionCaptureResult(outcome: .failed(.targetNotFrontmost), target: target)
        }
        guard target.focusedElement != nil else {
            return SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: target)
        }

        _ = target.targetApp.activate()
        try await wait(milliseconds: 120)
        if let failure = targetFailure(target) {
            return SelectionCaptureResult(outcome: .failed(failure), target: target)
        }
        guard isFrontmost(target) else {
            return SelectionCaptureResult(outcome: .failed(.targetNotFrontmost), target: target)
        }
        guard let before = axFocus(pid: target.pid), sameField(before, target) else {
            return SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: target)
        }

        let originalRange = before.range
        defer {
            if let originalRange,
               let current = axFocus(pid: target.pid),
               sameField(current, target),
               let element = current.element
            {
                _ = setSelectedRange(originalRange, on: element)
            }
        }

        try Task.checkCancellation()
        guard postCommandKey(KeyCode.a, toPid: target.pid) else {
            return SelectionCaptureResult(outcome: .failed(.keyEventCreationFailed), target: target)
        }
        try await wait(milliseconds: 60)

        guard let selectedAll = axFocus(pid: target.pid), sameField(selectedAll, target) else {
            return SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: target)
        }
        guard let selectedRange = selectedAll.range else {
            return SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: target)
        }
        if let element = selectedAll.element, let fullText = textValue(in: element) {
            if fullText.isEmpty, selectedRange.length == 0 {
                return SelectionCaptureResult(
                    outcome: .noSelection,
                    target: evidence(
                        app: target.targetApp,
                        baseline: nil,
                        scope: .entireDocument,
                        focus: selectedAll
                    )
                )
            }
            guard selectedText(in: selectedAll) == fullText else {
                return SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: target)
            }
        } else if selectedRange.length == 0 {
            return SelectionCaptureResult(outcome: .uncertain(.targetChanged), target: target)
        }

        let copy = try await copyCurrentSelection(
            pid: target.pid,
            initialFocus: selectedAll,
            pasteboard: pasteboard
        )
        try Task.checkCancellation()
        return captureResult(
            from: copy,
            app: target.targetApp,
            scope: .entireDocument
        )
    }

    /// Replace a captured target. Selection targets are reselected through AX
    /// and verified against their baseline. Document targets verify the same
    /// field, then ⌘A and verify the captured document again immediately before
    /// the commit-point ⌘V.
    static func apply(
        text: String,
        replacing target: SelectionTargetEvidence,
        pasteboard: NSPasteboard = .general
    ) async -> SelectionApplyOutcome {
        guard !text.isEmpty else { return .retained(.emptyReplacement) }
        guard let baseline = target.capturedBaseline else { return .retained(.missingBaseline) }
        guard let fieldBaseline = target.capturedFieldValue else {
            return .retained(.unverifiedTarget)
        }

        var snapshot: PasteboardSnapshot?
        var ownership: PasteboardOwnership?
        var committed = false
        var appliedTarget: SelectionTargetEvidence?
        var originalRange: CFRange?

        func restorePasteboard() -> Bool {
            guard let snapshot, let ownership else { return false }
            return snapshot.restore(to: pasteboard, ifOwnedBy: ownership)
        }

        defer {
            if !committed,
               let originalRange,
               let current = axFocus(pid: target.pid),
               sameField(current, target),
               let element = current.element
            {
                _ = setSelectedRange(originalRange, on: element)
            }
        }

        do {
            try Task.checkCancellation()
            if let failure = targetApplyFailure(target) { return .failure(failure) }
            guard isFrontmost(target) else { return .failure(.targetNotFrontmost) }

            _ = target.targetApp.activate()
            try await wait(milliseconds: 150)
            if let failure = targetApplyFailure(target) { return .failure(failure) }
            guard isFrontmost(target) else { return .retained(.targetChanged) }
            originalRange = axFocus(pid: target.pid)?.range

            let fieldValidation = validateField(target, expectedValue: fieldBaseline)
            guard case .valid = fieldValidation else {
                return applyOutcome(from: fieldValidation)
            }

            let prepared: Validation
            switch target.scope {
            case .selection:
                prepared = reselectAndValidate(target, baseline: baseline)
            case .entireDocument:
                try Task.checkCancellation()
                guard postCommandKey(KeyCode.a, toPid: target.pid) else {
                    return .failure(.keyEventCreationFailed)
                }
                try await wait(milliseconds: 40)
                prepared = validateSelectedTarget(target, baseline: baseline, reselect: false)
            }
            guard case .valid(let focus) = prepared else {
                return applyOutcome(from: prepared)
            }
            guard let appliedRange = focus.range else {
                return .retained(.unverifiedTarget)
            }
            guard let expectedFieldValue = replacing(
                fieldBaseline,
                range: appliedRange,
                with: text,
                entireDocument: target.scope == .entireDocument)
            else {
                return .retained(.unverifiedTarget)
            }

            snapshot = .capture(from: pasteboard)
            pasteboard.clearContents()
            ownership = .claim(pasteboard)
            guard pasteboard.setString(text, forType: .string) else {
                _ = restorePasteboard()
                return .failure(.unexpected("Mancia could not write the replacement to the pasteboard."))
            }
            ownership = .claim(pasteboard)

            let immediateValidation = validateSelectedTarget(
                target,
                baseline: baseline,
                reselect: false
            )
            guard case .valid = immediateValidation else {
                _ = restorePasteboard()
                return applyOutcome(from: immediateValidation)
            }
            if let failure = targetApplyFailure(target) {
                _ = restorePasteboard()
                return .failure(failure)
            }
            guard isFrontmost(target) else {
                _ = restorePasteboard()
                return .retained(.targetChanged)
            }
            guard let ownership,
                  ownership.matches(
                    changeCount: pasteboard.changeCount,
                    contents: .capture(from: pasteboard)
                  )
            else {
                return .retained(.pasteboardChanged)
            }

            try Task.checkCancellation()
            guard postCommandKey(KeyCode.v, toPid: target.pid) else {
                _ = restorePasteboard()
                return .failure(.keyEventCreationFailed)
            }
            committed = true
            try await postCommitDelay()
            guard let finalFocus = axFocus(pid: target.pid),
                  sameField(finalFocus, target),
                  textValue(in: finalFocus.element) == expectedFieldValue
            else {
                _ = restorePasteboard()
                return .failure(.unexpected(
                    "Mancia sent the paste but could not verify the resulting text. Check the document before trying again."
                ))
            }
            let verifiedTarget = SelectionTargetEvidence(
                pid: target.pid,
                capturedBaseline: text,
                capturedFieldValue: expectedFieldValue,
                scope: target.scope,
                targetApp: target.targetApp,
                window: finalFocus.window,
                focusedElement: finalFocus.element,
                selectedRange: CFRange(
                    location: appliedRange.location,
                    length: text.utf16.count)
            )
            appliedTarget = verifiedTarget
            return .applied(
                target: verifiedTarget,
                pasteboardRestored: restorePasteboard()
            )
        } catch is CancellationError {
            let restored = restorePasteboard()
            if committed, let appliedTarget {
                return .applied(target: appliedTarget, pasteboardRestored: restored)
            }
            return .cancelled
        } catch {
            let restored = restorePasteboard()
            if committed, let appliedTarget {
                return .applied(target: appliedTarget, pasteboardRestored: restored)
            }
            return .failure(.unexpected(error.localizedDescription))
        }
    }

    /// Verify and reselect a previously captured range without using the
    /// target application's undo stack.
    static func reselect(_ target: SelectionTargetEvidence) -> SelectionReselectionOutcome {
        guard let baseline = target.capturedBaseline else { return .retained(.missingBaseline) }
        guard target.scope == .selection else { return .retained(.unverifiedTarget) }
        if let failure = targetApplyFailure(target) { return .failure(failure) }
        guard isFrontmost(target) else { return .failure(.targetNotFrontmost) }
        switch reselectAndValidate(target, baseline: baseline) {
        case .valid:
            return .reselected(target)
        case .retained(let reason):
            return .retained(reason)
        case .failed(let failure):
            return .failure(failure)
        }
    }

    /// Screen rectangle (AppKit bottom-left-origin coordinates) of the focused
    /// element's selected text range / caret, via the Accessibility API.
    static func selectionScreenRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = elementAttribute(systemWide, kAXFocusedUIElementAttribute),
              let rangeValue = valueAttribute(element, kAXSelectedTextRangeAttribute)
        else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &axRect),
              axRect.origin.x.isFinite,
              axRect.origin.y.isFinite,
              axRect != .zero
        else { return nil }
        return appKitRect(fromAX: axRect)
    }

    static func appKitRect(fromAX axRect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(
            x: axRect.origin.x,
            y: primary.frame.maxY - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    // MARK: - Capture

    private static func captureSelection(
        in app: NSRunningApplication,
        pasteboard: NSPasteboard
    ) async throws -> SelectionCaptureResult {
        let pid = app.processIdentifier
        guard !app.isTerminated, NSRunningApplication(processIdentifier: pid) != nil else {
            return SelectionCaptureResult(outcome: .failed(.targetTerminated), target: nil)
        }
        guard AXIsProcessTrusted() else {
            return SelectionCaptureResult(
                outcome: .failed(.accessibilityPermissionRevoked),
                target: nil
            )
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return SelectionCaptureResult(outcome: .failed(.targetNotFrontmost), target: nil)
        }

        let focus = axFocus(pid: pid)
        let copy = try await copyCurrentSelection(
            pid: pid,
            initialFocus: focus,
            pasteboard: pasteboard
        )
        try Task.checkCancellation()
        return captureResult(from: copy, app: app, scope: .selection)
    }

    private static func captureResult(
        from copy: CopyResult,
        app: NSRunningApplication,
        scope: SelectionTargetEvidence.Scope
    ) -> SelectionCaptureResult {
        switch copy {
        case .selected(let text, let focus):
            return SelectionCaptureResult(
                outcome: .selected(text),
                target: evidence(app: app, baseline: text, scope: scope, focus: focus)
            )
        case .noSelection(let focus):
            return SelectionCaptureResult(
                outcome: .noSelection,
                target: evidence(app: app, baseline: nil, scope: scope, focus: focus)
            )
        case .uncertain(let failure):
            return SelectionCaptureResult(outcome: .uncertain(failure), target: nil)
        case .failed(let failure):
            return SelectionCaptureResult(outcome: .failed(failure), target: nil)
        }
    }

    private static func copyCurrentSelection(
        pid: pid_t,
        initialFocus: AXFocus?,
        pasteboard: NSPasteboard
    ) async throws -> CopyResult {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else {
            return .failed(.accessibilityPermissionRevoked)
        }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            return .failed(.targetTerminated)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .failed(.targetNotFrontmost)
        }
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let startCount = pasteboard.changeCount
        try Task.checkCancellation()
        guard postCommandKey(KeyCode.c, toPid: pid) else {
            return .failed(.keyEventCreationFailed)
        }

        var elapsed = 0
        var cancelled = false
        while elapsed < 600, pasteboard.changeCount == startCount {
            if cancelled {
                try await uncancellableWait(milliseconds: 30)
            } else {
                do {
                    try await wait(milliseconds: 30)
                } catch is CancellationError {
                    cancelled = true
                    try await uncancellableWait(milliseconds: 30)
                }
            }
            elapsed += 30
        }
        if Task.isCancelled { cancelled = true }

        let finalFocus = axFocus(pid: pid)
        let copiedText = pasteboard.string(forType: .string)
        let expectedSelectedText = finalFocus.flatMap(selectedText(in:))
        let ownership = pasteboard.changeCount == startCount
            ? nil
            : PasteboardOwnership.claimCopiedSelection(
                expectedSelectedText: expectedSelectedText,
                from: pasteboard)
        defer {
            if let ownership {
                _ = snapshot.restore(to: pasteboard, ifOwnedBy: ownership)
            }
        }
        if cancelled {
            throw CancellationError()
        }
        guard AXIsProcessTrusted() else {
            return .failed(.accessibilityPermissionRevoked)
        }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            return .failed(.targetTerminated)
        }
        guard stableField(initialFocus, finalFocus) else {
            return .uncertain(.targetChanged)
        }
        guard pasteboard.changeCount != startCount else {
            if finalFocus?.range?.length == 0 {
                return .noSelection(focus: finalFocus)
            }
            return .uncertain(.copyTimedOut)
        }

        guard let text = copiedText else {
            return .failed(.copiedContentIsNotText)
        }
        guard !text.isEmpty else {
            if finalFocus?.range?.length == 0 {
                return .noSelection(focus: finalFocus)
            }
            return .uncertain(.copyTimedOut)
        }
        if let expectedSelectedText, expectedSelectedText != text {
            return .uncertain(.targetChanged)
        }
        return .selected(text: text, focus: finalFocus)
    }

    // MARK: - Validation

    private static func reselectAndValidate(
        _ target: SelectionTargetEvidence,
        baseline: String
    ) -> Validation {
        guard let element = target.focusedElement, let range = target.selectedRange else {
            return .retained(.unverifiedTarget)
        }
        guard let current = axFocus(pid: target.pid), sameField(current, target) else {
            return .retained(.targetChanged)
        }
        guard setSelectedRange(range, on: element) else {
            return .failed(.rangeReselectionFailed)
        }
        return validateSelectedTarget(target, baseline: baseline, reselect: false)
    }

    private static func validateField(
        _ target: SelectionTargetEvidence,
        expectedValue: String
    ) -> Validation {
        guard target.focusedElement != nil else { return .retained(.unverifiedTarget) }
        guard let current = axFocus(pid: target.pid), sameField(current, target) else {
            return .retained(.targetChanged)
        }
        guard textValue(in: current.element) == expectedValue else {
            return .retained(.baselineChanged)
        }
        return .valid(current)
    }

    private static func validateSelectedTarget(
        _ target: SelectionTargetEvidence,
        baseline: String,
        reselect: Bool
    ) -> Validation {
        if reselect { return reselectAndValidate(target, baseline: baseline) }
        guard let expectedRange = target.selectedRange else {
            return .retained(.unverifiedTarget)
        }
        guard let current = axFocus(pid: target.pid), sameField(current, target) else {
            return .retained(.targetChanged)
        }
        guard let currentRange = current.range,
              sameRange(currentRange, expectedRange)
        else {
            return .retained(.selectedRangeChanged)
        }
        guard selectedText(in: current) == baseline else {
            return .retained(.baselineChanged)
        }
        guard let expectedFieldValue = target.capturedFieldValue,
              textValue(in: current.element) == expectedFieldValue
        else {
            return .retained(.baselineChanged)
        }
        return .valid(current)
    }

    private static func applyOutcome(from validation: Validation) -> SelectionApplyOutcome {
        switch validation {
        case .valid:
            return .retained(.unverifiedTarget)
        case .retained(let reason):
            return .retained(reason)
        case .failed(let failure):
            return .failure(failure)
        }
    }

    private static func targetFailure(
        _ target: SelectionTargetEvidence
    ) -> SelectionCaptureFailure? {
        guard !target.targetApp.isTerminated,
              NSRunningApplication(processIdentifier: target.pid) != nil
        else { return .targetTerminated }
        guard AXIsProcessTrusted() else { return .accessibilityPermissionRevoked }
        return nil
    }

    private static func targetApplyFailure(
        _ target: SelectionTargetEvidence
    ) -> SelectionApplyFailure? {
        guard !target.targetApp.isTerminated,
              NSRunningApplication(processIdentifier: target.pid) != nil
        else { return .targetTerminated }
        guard AXIsProcessTrusted() else { return .accessibilityPermissionRevoked }
        return nil
    }

    private static func isFrontmost(_ target: SelectionTargetEvidence) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }

    // MARK: - Accessibility

    private static func axFocus(pid: pid_t) -> AXFocus? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, 0.25)
        let window = elementAttribute(application, kAXFocusedWindowAttribute)
        let element = elementAttribute(application, kAXFocusedUIElementAttribute)
        if let element { _ = AXUIElementSetMessagingTimeout(element, 0.25) }
        return AXFocus(
            window: window,
            element: element,
            range: element.flatMap(selectedRange(in:))
        )
    }

    private static func evidence(
        app: NSRunningApplication,
        baseline: String?,
        scope: SelectionTargetEvidence.Scope,
        focus: AXFocus?
    ) -> SelectionTargetEvidence {
        SelectionTargetEvidence(
            pid: app.processIdentifier,
            capturedBaseline: baseline,
            capturedFieldValue: focus?.element.flatMap(textValue(in:)),
            scope: scope,
            targetApp: app,
            window: focus?.window,
            focusedElement: focus?.element,
            selectedRange: focus?.range
        )
    }

    private static func stableField(_ before: AXFocus?, _ after: AXFocus?) -> Bool {
        guard let before, let after else { return true }
        switch (before.element, after.element) {
        case (.none, .none):
            break
        case (.some(let beforeElement), .some(let afterElement))
            where CFEqual(beforeElement, afterElement):
            break
        default:
            return false
        }
        switch (before.window, after.window) {
        case (.none, .none):
            break
        case (.some(let beforeWindow), .some(let afterWindow))
            where CFEqual(beforeWindow, afterWindow):
            break
        default:
            return false
        }
        return true
    }

    private static func sameField(_ current: AXFocus, _ target: SelectionTargetEvidence) -> Bool {
        guard let expectedElement = target.focusedElement,
              let currentElement = current.element,
              CFEqual(expectedElement, currentElement)
        else { return false }
        if let expectedWindow = target.window {
            guard let currentWindow = current.window, CFEqual(expectedWindow, currentWindow) else {
                return false
            }
        }
        return true
    }

    private static func sameRange(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        guard let value = valueAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    private static func selectedText(in focus: AXFocus) -> String? {
        guard let element = focus.element else { return nil }
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
           let text = selectedValue as? String
        {
            return text
        }

        guard let range = focus.range,
              range.location >= 0,
              range.length >= 0
        else { return nil }
        guard let text = textValue(in: element),
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location
        else { return nil }
        return (text as NSString).substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }

    private static func textValue(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success
        else { return nil }
        return value as? String
    }

    private static func textValue(in element: AXUIElement?) -> String? {
        element.flatMap(textValue(in:))
    }

    private static func replacing(
        _ field: String,
        range: CFRange,
        with replacement: String,
        entireDocument: Bool
    ) -> String? {
        if entireDocument { return replacement }
        guard range.location >= 0,
              range.length >= 0,
              range.location <= field.utf16.count,
              range.length <= field.utf16.count - range.location
        else { return nil }
        return (field as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement)
    }

    private static func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func valueAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    // MARK: - Events and waits

    private static func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(milliseconds))
        try Task.checkCancellation()
    }

    /// The detached delay is deliberately not cancelled with the caller after
    /// ⌘V. Restoring the pasteboard before the target consumes the paste would
    /// turn a post-commit cancellation into the wrong edit.
    private static func postCommitDelay() async throws {
        try await uncancellableWait(milliseconds: 1_000)
    }

    private static func uncancellableWait(milliseconds: Int) async throws {
        let delay = Task.detached {
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
        try await delay.value
    }

    private static func postCommandKey(_ keyCode: CGKeyCode, toPid pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              )
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
