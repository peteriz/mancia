import AppKit

struct CoordinatorOperationEpoch: Equatable {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        value == candidate
    }
}

enum SelectionRefreshDecision: Equatable {
    case reuseTarget
    case reactivateTarget
    case captureFrontmost

    static func decide(frontmostPid: pid_t?, targetPid: pid_t, ownPid: pid_t) -> Self {
        if frontmostPid == targetPid { return .reuseTarget }
        if frontmostPid == ownPid { return .reactivateTarget }
        return .captureFrontmost
    }
}

/// Orchestrates capture, explicit scope approval, generation, verified apply,
/// and AX-backed version navigation for one ribbon session.
@MainActor
final class EditCoordinator {
    private struct PendingAction {
        let action: EditAction
        let note: String?
    }

    private struct PendingApply {
        let target: SelectionTargetEvidence
        let actionName: String
    }

    private let provider: LLMProvider
    private let settings: AppSettings
    private let model = PanelModel()
    private lazy var ribbon: RibbonWindow = {
        let ribbon = RibbonWindow(model: model, settings: settings)
        ribbon.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        ribbon.onPointerActivity = { [weak self] in
            self?.autoCloseTask?.cancel()
            self?.autoCloseTask = nil
        }
        ribbon.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        return ribbon
    }()

    private var capture: SelectionCaptureResult?
    private var currentTask: Task<Void, Never>?
    private var autoCloseTask: Task<Void, Never>?
    private var queuedAction: PendingAction?
    private var pendingDocumentAction: PendingAction?
    private var pendingApply: PendingApply?
    private var capturing = false
    private var navigating = false
    private var sessionActive = false
    private var operationEpoch = CoordinatorOperationEpoch()
    private var session = EditSession(
        ownPid: NSRunningApplication.current.processIdentifier)

    var onOpenSettings: (() -> Void)?

    init(provider: LLMProvider, settings: AppSettings) {
        self.provider = provider
        self.settings = settings
        wire()
    }

    private func wire() {
        model.onPerform = { [weak self] action, note in
            self?.perform(action, note: note)
        }
        model.onScopeChange = { [weak self] scope in
            self?.scopeChanged(scope)
        }
        model.onUndoVersion = { [weak self] in
            self?.undoLastVersion() ?? false
        }
        model.onRetry = { [weak self] in self?.retry() }
        model.onApproveDocumentGeneration = { [weak self] in
            self?.approveDocumentGeneration()
        }
        model.onConfirmApply = { [weak self] in self?.confirmApply() }
        model.onDeclinePending = { [weak self] in self?.declinePending() }
        model.onCopyRetainedResult = { [weak self] in self?.copyRetainedResult() }
        model.onCancelRun = { [weak self] in self?.cancelRun() }
        model.onCancel = { [weak self] in self?.cancel() }
    }

    func start() {
        guard !sessionActive else {
            ribbon.focus()
            return
        }
        guard ensureAccessibility() else { return }

        sessionActive = true
        autoCloseTask?.cancel()
        clearPending()
        capture = nil
        navigating = false
        capturing = true
        model.reset(hasSelection: true, charCount: 0)
        model.capturing = true
        ribbon.show()
        ribbon.focus()
        warmProvider()

        startOperation { [self] operation in
            do {
                let result = try await SelectionCapture.captureSelection()
                try Task.checkCancellation()
                guard self.isCurrent(operation) else { return }
                finishInitialCapture(result)
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(operation) else { return }
                capturing = false
                model.capturing = false
                fail(error.localizedDescription)
            }
        }
    }

    private func finishInitialCapture(_ result: SelectionCaptureResult) {
        capture = result
        model.targetAppName = result.target?.targetApp.localizedName ?? ""
        capturing = false
        model.capturing = false

        let evidence = sessionEvidence(from: result)
        _ = session.begin(with: evidence)
        switch result.outcome {
        case .selected(let text):
            model.hasSelection = true
            model.selectionCharCount = text.count
            model.scope = .selection
        case .noSelection:
            model.hasSelection = false
            model.selectionCharCount = 0
            model.scope = .document
        case .uncertain(let failure), .failed(let failure):
            model.hasSelection = false
            model.selectionCharCount = 0
            model.scope = .selection
            fail(captureGuidance(for: failure))
        }
        syncIterationState()

        if let queuedAction {
            self.queuedAction = nil
            perform(queuedAction.action, note: queuedAction.note)
        }
    }

    // MARK: - Generation

    private func perform(_ action: EditAction, note: String?) {
        if capturing {
            queuedAction = PendingAction(action: action, note: note)
            model.runningTitle = action.progressLabel
            model.phase = .running
            return
        }

        autoCloseTask?.cancel()
        autoCloseTask = nil
        pendingApply = nil
        clearRetainedPresentation()
        model.pendingResultPreview = ""
        model.pendingOriginalPreview = ""
        model.appliedStatusText = nil
        if session.stage != .idle {
            _ = session.cancel(at: cancellationBoundary(for: session.stage))
        }
        session.setScope(sessionScope)
        let pending = PendingAction(action: action, note: note)
        model.runningTitle = sessionScope == .selection ? "Reading selection" : action.progressLabel
        model.phase = .running
        ribbon.focus()

        startOperation { [self] operation in
            do {
                if sessionScope == .selection {
                    try await refreshSelectionTarget(operation: operation)
                }
                try Task.checkCancellation()
                guard self.isCurrent(operation) else { return }
                await handleGenerationDecision(
                    session.requestGeneration(),
                    pending: pending,
                    operation: operation
                )
            } catch is CancellationError {
                guard self.isCurrent(operation) else { return }
                _ = session.cancel(at: .beforeGeneration)
                restoreRestingPhase()
            } catch {
                guard self.isCurrent(operation) else { return }
                _ = session.fail()
                fail(error.localizedDescription)
            }
        }
    }

    private func refreshSelectionTarget(operation: UInt64) async throws {
        guard let capture, let target = capture.target else {
            throw CoordinatorError.uncertainTarget
        }
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let refreshed: SelectionCaptureResult
        let refreshDecision = SelectionRefreshDecision.decide(
            frontmostPid: frontmostPid,
            targetPid: target.pid,
            ownPid: NSRunningApplication.current.processIdentifier
        )
        switch refreshDecision {
        case .reuseTarget, .reactivateTarget:
            refreshed = try await SelectionCapture.captureFreshSelection(from: capture)
        case .captureFrontmost:
            refreshed = try await SelectionCapture.captureSelection()
        }
        try Task.checkCancellation()
        guard isCurrent(operation) else { throw CancellationError() }
        guard refreshed.target?.pid != NSRunningApplication.current.processIdentifier else {
            throw CoordinatorError.uncertainTarget
        }

        switch refreshed.outcome {
        case .selected(let text):
            guard session.adopt(sessionEvidence(from: refreshed)) == nil else {
                throw CoordinatorError.uncertainTarget
            }
            self.capture = refreshed
            model.targetAppName = refreshed.target?.targetApp.localizedName ?? ""
            model.hasSelection = true
            model.selectionCharCount = text.count
            model.scope = .selection
            ribbon.noteSelectionMoved(SelectionCapture.selectionScreenRect())
        case .noSelection:
            guard refreshDecision != .captureFrontmost, session.versionCount > 1 else {
                throw CoordinatorError.noSelection
            }
            // After a verified paste, a standard text view normally leaves a
            // caret. The saved AX range is the only safe iteration target.
        case .uncertain(let failure), .failed(let failure):
            throw CoordinatorError.capture(failure)
        }
    }

    private func handleGenerationDecision(
        _ decision: EditSession.GenerationDecision,
        pending: PendingAction,
        operation: UInt64
    ) async {
        guard isCurrent(operation) else { return }
        switch decision {
        case .requestDocumentApproval:
            pendingDocumentAction = pending
            model.pendingScopeApprovalActionTitle = pending.action.title
            model.phase = .scopeApproval
            ribbon.focus()
        case .captureDocument:
            fail("Approve document access before Mancia reads it.")
        case .send(let request):
            guard let target = capture?.target else {
                _ = session.fail()
                fail(CoordinatorError.uncertainTarget.localizedDescription)
                return
            }
            await generate(
                pending,
                request: request,
                target: target,
                operation: operation)
        case .failure(let failure):
            fail(message(for: failure))
        }
    }

    private func approveDocumentGeneration() {
        guard model.phase == .scopeApproval,
              let pending = pendingDocumentAction,
              let capture
        else { return }

        pendingDocumentAction = nil
        model.pendingScopeApprovalActionTitle = ""
        model.runningTitle = "Reading document"
        model.phase = .running

        switch session.approveDocumentGeneration() {
        case .captureDocument:
            startOperation { [self] operation in
                do {
                    let document = try await SelectionCapture.captureEntireDocument(
                        from: capture)
                    try Task.checkCancellation()
                    guard self.isCurrent(operation) else { return }
                    guard case .selected(let text) = document.outcome,
                          let targetID = targetID(from: document.target)
                    else {
                        _ = session.acceptDocumentCapture(.uncertain)
                        retain(
                            output: "",
                            reason: documentFailureMessage(document.outcome)
                        )
                        return
                    }
                    self.capture = document
                    let decision = session.acceptDocumentCapture(
                        .captured(text: text, target: targetID))
                    await handleGenerationDecision(
                        decision,
                        pending: pending,
                        operation: operation)
                } catch is CancellationError {
                    guard self.isCurrent(operation) else { return }
                    _ = session.cancel(at: .beforeGeneration)
                    restoreRestingPhase()
                } catch {
                    guard self.isCurrent(operation) else { return }
                    _ = session.fail()
                    fail(error.localizedDescription)
                }
            }
        case .failure(let failure):
            fail(message(for: failure))
        default:
            fail("The document approval is no longer current.")
        }
    }

    private func generate(
        _ pending: PendingAction,
        request: EditSession.GenerationRequest,
        target: SelectionTargetEvidence,
        operation: UInt64
    ) async {
        guard isCurrent(operation) else { return }
        model.runningTitle = pending.action.progressLabel
        model.phase = .running
        ribbon.focus()

        do {
            try PromptGuard.validate(
                action: pending.action,
                text: request.text,
                note: pending.note)
            let prompt = PromptBuilder.build(
                action: pending.action,
                text: request.text,
                note: pending.note)
            let rawOutput = try await provider.complete(prompt)
            try Task.checkCancellation()
            guard isCurrent(operation) else { return }
            let output = try PromptBuilder.normalizeOutput(
                action: pending.action,
                source: request.text,
                output: rawOutput,
                preserveSourceBoundaryWhitespace: request.baseline.scope == .selection)
            let result = EditSession.GeneratedResult(output: output, for: request)
            switch session.consider(
                result,
                replacementConfirmationRequired:
                    ApplyConfirmation.requiresReplacementApproval(
                        isWholeDocument: request.baseline.scope == .document,
                        userOptedIn: settings.confirmWholeDocumentReplace)
            ) {
            case .retained:
                syncIterationState()
                model.appliedStatusText = "No changes needed"
                model.restoreButtonsAfterApply()
                model.phase = .applied
                ribbon.focus()
                scheduleAutoCloseIfHybrid()
            case .requestReplacementApproval(let result):
                pendingApply = PendingApply(
                    target: target,
                    actionName: pending.action.title)
                presentReplacementConfirmation(result)
            case .apply(let plan):
                await executeApply(
                    plan,
                    target: target,
                    actionName: pending.action.title,
                    operation: operation)
            case .failure(let failure):
                fail(message(for: failure))
            }
        } catch is CancellationError {
            guard isCurrent(operation) else { return }
            _ = session.cancel(at: .generation)
            restoreRestingPhase()
        } catch {
            guard isCurrent(operation) else { return }
            _ = session.fail()
            fail(error.localizedDescription)
        }
    }

    // MARK: - Apply and retention

    private func presentReplacementConfirmation(
        _ result: EditSession.GeneratedResult
    ) {
        model.pendingOriginalCharCount = result.baseline.text.count
        model.pendingResultCharCount = result.output.count
        model.pendingResultPreview = result.output
        model.pendingOriginalPreview = result.baseline.text
        model.phase = .confirm
        ribbon.focus()
    }

    private func confirmApply() {
        guard model.phase == .confirm,
              let pendingApply
        else { return }
        guard case .apply(let plan) = session.approveReplacement() else {
            fail("The pending replacement is no longer current.")
            return
        }

        self.pendingApply = nil
        model.pendingResultPreview = ""
        model.pendingOriginalPreview = ""
        model.runningTitle = "Replacing document"
        model.phase = .running
        startOperation { [self] operation in
            await executeApply(
                plan,
                target: pendingApply.target,
                actionName: pendingApply.actionName,
                operation: operation)
        }
    }

    private func executeApply(
        _ plan: EditSession.ApplyPlan,
        target: SelectionTargetEvidence,
        actionName: String,
        operation: UInt64
    ) async {
        guard isCurrent(operation) else { return }
        model.runningTitle = "Applying"
        model.phase = .running
        ribbon.focus()
        let outcome = await SelectionCapture.apply(
            text: plan.result.output,
            replacing: target)
        guard isCurrent(operation) else { return }

        switch outcome {
        case .applied(let appliedTarget, _):
            let evidence = appliedEvidence(
                text: plan.result.output,
                target: appliedTarget)
            guard session.finishApply(plan, outcome: .applied(evidence)) else {
                retain(
                    output: plan.result.output,
                    reason: "Mancia pasted the text but could not verify its history metadata."
                )
                return
            }
            capture = SelectionCaptureResult(
                outcome: .selected(plan.result.output),
                target: appliedTarget)
            dodgeAppliedText()
            finishApplied(actionName: actionName)
        case .retained(let reason):
            _ = session.finishApply(plan, outcome: .retained)
            retain(
                output: plan.result.output,
                reason: reason.localizedDescription)
        case .cancelled:
            _ = session.finishApply(plan, outcome: .cancelled(.apply))
            restoreRestingPhase()
        case .failure(let failure):
            _ = session.finishApply(
                plan,
                outcome: .failure(.operationFailed))
            retain(
                output: plan.result.output,
                reason: failure.localizedDescription)
        }
    }

    private func finishApplied(actionName: String) {
        syncIterationState()
        model.appliedStatusText = nil
        model.appliedActionName = actionName
        model.restoreButtonsAfterApply()
        model.phase = .applied
        ribbon.focus()
        scheduleAutoCloseIfHybrid()
    }

    private func retain(output: String, reason: String) {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        if !output.isEmpty {
            model.retainedResult = output
        }
        model.retainedReason = reason
        model.pendingResultPreview = ""
        model.pendingOriginalPreview = ""
        model.phase = .retained
        ribbon.focus()
    }

    private func declinePending() {
        switch model.phase {
        case .scopeApproval:
            pendingDocumentAction = nil
            model.pendingScopeApprovalActionTitle = ""
            _ = session.cancel(at: .beforeGeneration)
            restoreRestingPhase()
        case .confirm:
            let output = model.pendingResultPreview
            _ = session.retainPendingResult()
            pendingApply = nil
            retain(
                output: output,
                reason: "The document replacement was not applied.")
        default:
            break
        }
    }

    private func copyRetainedResult() {
        guard !model.retainedResult.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.retainedResult, forType: .string)
    }

    // MARK: - History

    @discardableResult
    private func restoreVersion(at index: Int) -> Bool {
        guard model.phase == .applied,
              !navigating,
              let plan = session.navigation(to: index),
              let target = navigationTarget(for: plan)
        else { return false }

        autoCloseTask?.cancel()
        autoCloseTask = nil
        navigating = true
        model.undoAvailable = false
        model.runningTitle = "Restoring version"
        model.phase = .running
        ribbon.focus()
        startOperation { [self] operation in
            defer {
                if self.isCurrent(operation) {
                    navigating = false
                }
            }
            let outcome = await SelectionCapture.apply(
                text: plan.replacement,
                replacing: target)
            guard self.isCurrent(operation) else { return }
            switch outcome {
            case .applied(let appliedTarget, _):
                let evidence = appliedEvidence(
                    text: plan.replacement,
                    target: appliedTarget)
                guard session.finishNavigation(
                    plan,
                    outcome: .applied(evidence))
                else {
                    retain(
                        output: plan.replacement,
                        reason: "Mancia could not verify the restored version.")
                    return
                }
                capture = SelectionCaptureResult(
                    outcome: .selected(plan.replacement),
                    target: appliedTarget)
                dodgeAppliedText()
                syncIterationState()
                model.appliedStatusText = "Previous version restored"
                model.phase = .applied
                ribbon.focus()
            case .retained(let reason):
                _ = session.finishNavigation(plan, outcome: .retained)
                retain(output: plan.replacement, reason: reason.localizedDescription)
            case .cancelled:
                _ = session.finishNavigation(
                    plan,
                    outcome: .cancelled(.navigation))
                restoreRestingPhase()
            case .failure(let failure):
                _ = session.finishNavigation(
                    plan,
                    outcome: .failure(.operationFailed))
                retain(output: plan.replacement, reason: failure.localizedDescription)
            }
        }
        return true
    }

    private func undoLastVersion() -> Bool {
        restoreVersion(at: session.currentIndex - 1)
    }

    private func navigationTarget(
        for plan: EditSession.NavigationPlan
    ) -> SelectionTargetEvidence? {
        guard let current = capture?.target,
              current.pid == plan.current.target.pid,
              current.elementIdentifier == plan.current.target.elementIdentifier
        else { return nil }
        let scope: SelectionTargetEvidence.Scope
        let range: CFRange?
        switch plan.current.scope {
        case .selection:
            guard let selectedRange = plan.current.range else { return nil }
            scope = .selection
            range = CFRange(
                location: selectedRange.location,
                length: selectedRange.length)
        case .document:
            scope = .entireDocument
            range = current.selectedRange
        }
        return SelectionTargetEvidence(
            pid: current.pid,
            capturedBaseline: plan.current.text,
            capturedFieldValue: current.capturedFieldValue,
            scope: scope,
            targetApp: current.targetApp,
            window: current.window,
            focusedElement: current.focusedElement,
            selectedRange: range
        )
    }

    // MARK: - Session lifecycle

    private func scopeChanged(_ scope: PanelModel.Scope) {
        invalidateOperation()
        autoCloseTask?.cancel()
        autoCloseTask = nil
        pendingDocumentAction = nil
        pendingApply = nil
        model.pendingScopeApprovalActionTitle = ""
        model.pendingOriginalCharCount = 0
        model.pendingResultCharCount = 0
        model.pendingResultPreview = ""
        model.pendingOriginalPreview = ""
        model.appliedStatusText = nil
        clearRetainedPresentation()
        session.setScope(scope == .document ? .document : .selection)
        restoreRestingPhase()
    }

    private func retry() {
        model.runPrimary()
    }

    private func cancelRun() {
        if model.phase == .confirm {
            declinePending()
            return
        }
        if capturing {
            queuedAction = nil
            model.phase = .idle
            ribbon.focus()
            return
        }
        currentTask?.cancel()
        autoCloseTask?.cancel()
        autoCloseTask = nil
    }

    func refocusPanel() {
        ribbon.focus()
    }

    private func cancel() {
        invalidateOperation()
        autoCloseTask?.cancel()
        autoCloseTask = nil
        clearPending()
        capture = nil
        queuedAction = nil
        capturing = false
        navigating = false
        model.instruction = ""
        model.errorText = ""
        model.runningTitle = ""
        model.appliedActionName = ""
        model.appliedStatusText = nil
        clearRetainedPresentation()
        sessionActive = false
        ribbon.close()
        warmProviderAfterClose()
    }

    private func clearPending() {
        queuedAction = nil
        pendingDocumentAction = nil
        pendingApply = nil
        model.pendingScopeApprovalActionTitle = ""
        model.pendingOriginalCharCount = 0
        model.pendingResultCharCount = 0
        model.pendingResultPreview = ""
        model.pendingOriginalPreview = ""
    }

    private func clearRetainedPresentation() {
        model.retainedResult = ""
        model.retainedReason = ""
    }

    private func restoreRestingPhase() {
        syncIterationState()
        model.phase = session.versionCount > 1 ? .applied : .idle
        ribbon.focus()
    }

    private func syncIterationState() {
        model.versionCount = session.versionCount
        model.currentIndex = session.currentIndex
        let target = capture?.target
        let targetIsNavigable = switch target?.scope {
        case .selection:
            target?.hasVerifiedRangeIdentity == true
        case .entireDocument:
            target?.focusedElement != nil && target?.capturedFieldValue != nil
        case nil:
            false
        }
        model.undoAvailable = session.currentIndex > 0 && targetIsNavigable
    }

    private var sessionScope: EditSession.Scope {
        model.scope == .document ? .document : .selection
    }

    private func cancellationBoundary(
        for stage: EditSession.Stage
    ) -> EditSession.CancellationBoundary {
        switch stage {
        case .generating:
            .generation
        case .applying:
            .apply
        case .navigating:
            .navigation
        case .idle, .awaitingDocumentApproval, .capturingDocument,
             .awaitingReplacementApproval:
            .beforeGeneration
        }
    }

    private func dodgeAppliedText() {
        ribbon.avoidUpdatedText(caretRect: SelectionCapture.selectionScreenRect())
    }

    // MARK: - Evidence mapping

    private func sessionEvidence(
        from result: SelectionCaptureResult
    ) -> EditSession.CaptureEvidence {
        guard let targetID = targetID(from: result.target) else {
            return .uncertain(targetPid: result.target?.pid)
        }
        switch result.outcome {
        case .selected(let text):
            return .selection(.init(
                text: text,
                target: targetID,
                range: result.target?.selectedRange.map {
                    .init(location: $0.location, length: $0.length)
                }))
        case .noSelection:
            return .noSelection(targetID)
        case .uncertain, .failed:
            return .uncertain(targetPid: result.target?.pid)
        }
    }

    private func targetID(
        from target: SelectionTargetEvidence?
    ) -> EditSession.TargetID? {
        guard let target else { return nil }
        return .init(
            pid: target.pid,
            elementIdentifier: target.elementIdentifier)
    }

    private func appliedEvidence(
        text: String,
        target: SelectionTargetEvidence
    ) -> EditSession.AppliedEvidence {
        let targetID = targetID(from: target)
            ?? .init(pid: target.pid, elementIdentifier: nil)
        switch target.scope {
        case .selection:
            let range = target.selectedRange.map {
                EditSession.TextRange(location: $0.location, length: $0.length)
            } ?? .init(location: -1, length: 0)
            return .init(
                text: text,
                target: .selection(target: targetID, range: range))
        case .entireDocument:
            return .init(text: text, target: .document(targetID))
        }
    }

    // MARK: - Presentation

    private func message(for failure: EditSession.Failure) -> String {
        switch failure {
        case .busy:
            "Finish or cancel the current action first."
        case .uncertainCapture:
            "Mancia could not prove what text is selected. Select the text again in a standard editable field."
        case .noSelection:
            "There is no selected text to edit."
        case .emptyInput:
            "There is no text to edit."
        case .emptyResult:
            "The provider returned no text."
        case .invalidTarget, .missingReselectionMetadata:
            "Mancia can read this host, but cannot safely replace its text. Use Copy instead."
        case .targetChanged, .staleResult:
            "The target changed. Run the action again on the current selection."
        case .invalidTransition:
            "That approval is no longer current."
        case .operationFailed:
            "Mancia could not complete the edit."
        }
    }

    private func captureGuidance(for failure: SelectionCaptureFailure) -> String {
        switch failure {
        case .copyTimedOut, .targetChanged:
            "Mancia could not tell whether this app has a selection. Select text in a standard editable field and try again."
        default:
            failure.localizedDescription
        }
    }

    private func documentFailureMessage(_ outcome: SelectionReadOutcome) -> String {
        switch outcome {
        case .selected:
            "Mancia could not verify the document target."
        case .noSelection:
            "The document is empty."
        case .uncertain(let failure), .failed(let failure):
            captureGuidance(for: failure)
        }
    }

    private func fail(_ message: String) {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        model.errorText = message
        model.phase = .error
        ribbon.focus()
    }

    // MARK: - Post-apply behavior

    private func scheduleAutoCloseIfHybrid() {
        autoCloseTask?.cancel()
        guard settings.postApplyBehavior == .hybrid else {
            autoCloseTask = nil
            return
        }
        autoCloseTask = Task {
            let operation = operationEpoch.value
            do {
                try await Task.sleep(for: .milliseconds(1200))
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard isCurrent(operation),
                  model.phase == .applied,
                  ribbon.isKey
            else { return }
            cancel()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        return false
    }

    private func startOperation(
        _ body: @escaping @MainActor (UInt64) async -> Void
    ) {
        let operation = operationEpoch.advance()
        let previous = currentTask
        previous?.cancel()
        currentTask = Task { [weak self] in
            await previous?.value
            guard let self,
                  self.isCurrent(operation),
                  !Task.isCancelled
            else { return }
            await body(operation)
        }
    }

    private func invalidateOperation() {
        _ = operationEpoch.advance()
        currentTask?.cancel()
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        operationEpoch.isCurrent(operation)
    }

    private func warmProvider() {
        guard let provider = provider as? WarmableLLMProvider else { return }
        Task { await provider.prepareForPanel() }
    }

    private func warmProviderAfterClose() {
        guard let provider = provider as? WarmableLLMProvider else { return }
        Task { await provider.panelDidClose() }
    }

    // MARK: - Accessibility

    private func ensureAccessibility() -> Bool {
        if Permissions.isAccessibilityTrusted { return true }
        Permissions.requestAccessibility()
        onOpenSettings?()
        return false
    }
}

private enum CoordinatorError: LocalizedError {
    case noSelection
    case uncertainTarget
    case capture(SelectionCaptureFailure)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "There is no selected text to edit."
        case .uncertainTarget:
            "Mancia could not verify the selected field. Select the text again in a standard editable field."
        case .capture(let failure):
            failure.localizedDescription
        }
    }
}
