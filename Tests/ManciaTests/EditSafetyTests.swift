import AppKit
import Testing
@testable import Mancia

@Suite("Edit safety")
struct EditSafetyTests {
    private let targetA = EditSession.TargetID(pid: 501, elementIdentifier: 11)
    private let targetB = EditSession.TargetID(pid: 501, elementIdentifier: 22)
    private let range = EditSession.TextRange(location: 4, length: 8)

    @Test("Whole-document text is not captured or sent before approval")
    func documentRequiresApprovalBeforeCapture() throws {
        var session = EditSession(ownPid: 99)
        let beginFailure = session.begin(with: .noSelection(targetA))
        #expect(beginFailure == nil)

        let approval = session.requestGeneration()
        #expect(approval == .requestDocumentApproval)
        #expect(session.stage == .awaitingDocumentApproval)
        let capture = session.approveDocumentGeneration()
        #expect(capture == .captureDocument(targetA))
        #expect(session.stage == .capturingDocument)

        let decision = session.acceptDocumentCapture(
            .captured(text: "document", target: targetA))
        guard case .send(let request) = decision else {
            Issue.record("approved document should become a generation request")
            return
        }
        #expect(request.text == "document")
        #expect(request.baseline.scope == .document)
    }

    @Test("Uncertain capture never becomes whole-document generation")
    func uncertainCaptureDoesNotEscalate() {
        var session = EditSession(ownPid: 99)
        let beginFailure = session.begin(with: .uncertain(targetPid: 501))
        #expect(beginFailure == nil)
        let decision = session.requestGeneration()
        #expect(decision == .failure(.uncertainCapture))
        #expect(session.stage == .idle)
    }

    @Test("Scope changes make generated output stale")
    func scopeChangeInvalidatesResult() throws {
        var session = selectionSession()
        let request = try generationRequest(from: &session)
        let result = EditSession.GeneratedResult(output: "changed", for: request)

        session.setScope(.document)

        #expect(
            session.consider(result, replacementConfirmationRequired: false)
                == .failure(.staleResult))
        #expect(session.versionCount == 0)
    }

    @Test("Unchanged output is a no-op without paste or history")
    func unchangedOutputIsNoOp() throws {
        var session = selectionSession()
        let request = try generationRequest(from: &session)
        let result = EditSession.GeneratedResult(output: request.text, for: request)

        #expect(
            session.consider(result, replacementConfirmationRequired: false)
                == .retained)
        #expect(session.versionCount == 0)
        #expect(session.stage == .idle)
    }

    @Test("Missing AX range still permits generation but cannot create history")
    func unverifiedSelectionFallsBackAfterGeneration() throws {
        var session = EditSession(ownPid: 99)
        let target = EditSession.TargetID(pid: 501, elementIdentifier: nil)
        _ = session.begin(with: .selection(.init(
            text: "readable text",
            target: target,
            range: nil)))

        let request = try generationRequest(from: &session)
        let result = EditSession.GeneratedResult(output: "generated text", for: request)
        guard case .apply(let plan) = session.consider(
            result,
            replacementConfirmationRequired: false)
        else {
            Issue.record("generation without AX should still produce a copyable result")
            return
        }

        let finished = session.finishApply(plan, outcome: .retained)
        #expect(finished)
        #expect(session.versionCount == 0)
    }

    @Test("Only verified apply creates positive history")
    func historyRequiresVerifiedApply() throws {
        var retained = selectionSession()
        let retainedPlan = try applyPlan(from: &retained, output: "result")
        let retainedFinished = retained.finishApply(retainedPlan, outcome: .retained)
        #expect(retainedFinished)
        #expect(retained.versionCount == 0)

        var applied = selectionSession()
        let appliedPlan = try applyPlan(from: &applied, output: "result")
        let evidence = EditSession.AppliedEvidence(
            text: "result",
            target: .selection(
                target: targetA,
                range: .init(location: range.location, length: 6)))
        let appliedFinished = applied.finishApply(
            appliedPlan,
            outcome: .applied(evidence))
        #expect(appliedFinished)
        #expect(applied.versionTexts == ["original", "result"])
        #expect(applied.currentIndex == 1)
    }

    @Test("History index moves only after verified navigation")
    func navigationCommitsLate() throws {
        var session = try appliedSession()
        let firstNavigation = session.navigation(to: 0)
        let plan = try #require(firstNavigation)
        #expect(session.currentIndex == 1)

        let retainedFinished = session.finishNavigation(plan, outcome: .retained)
        #expect(retainedFinished)
        #expect(session.currentIndex == 1)

        let nextNavigation = session.navigation(to: 0)
        let secondPlan = try #require(nextNavigation)
        let evidence = EditSession.AppliedEvidence(
            text: "original",
            target: .selection(
                target: targetA,
                range: .init(location: range.location, length: 8)))
        let appliedFinished = session.finishNavigation(
            secondPlan,
            outcome: .applied(evidence))
        #expect(appliedFinished)
        #expect(session.currentIndex == 0)
    }

    @Test("Whole-document history branches only after verified navigation")
    func documentHistorySupportsUndoAndBranching() throws {
        var session = EditSession(ownPid: 99)
        _ = session.begin(with: .noSelection(targetA))

        try applyDocumentResult("v1", currentText: "original", to: &session)
        try applyDocumentResult("v2", currentText: "v1", to: &session)
        #expect(session.versionTexts == ["original", "v1", "v2"])

        let undoPlan = session.navigation(to: 1)
        let undo = try #require(undoPlan)
        #expect(session.currentIndex == 2)
        let undoFinished = session.finishNavigation(
            undo,
            outcome: .applied(.init(
                text: "v1",
                target: .document(targetA))))
        #expect(undoFinished)
        #expect(session.currentIndex == 1)

        try applyDocumentResult("v3", currentText: "v1", to: &session)
        #expect(session.versionTexts == ["original", "v1", "v3"])
        #expect(session.currentIndex == 2)
    }

    @Test("Whole-document navigation never commits stale or failed outcomes")
    func documentNavigationRejectsUnverifiedOutcome() throws {
        var session = EditSession(ownPid: 99)
        _ = session.begin(with: .noSelection(targetA))
        try applyDocumentResult("v1", currentText: "original", to: &session)

        let stalePlan = session.navigation(to: 0)
        let stale = try #require(stalePlan)
        let staleFinished = session.finishNavigation(
            stale,
            outcome: .applied(.init(
                text: "original",
                target: .document(targetB))))
        #expect(!staleFinished)
        #expect(session.currentIndex == 1)

        let failedPlan = session.navigation(to: 0)
        let failed = try #require(failedPlan)
        let failedFinished = session.finishNavigation(
            failed,
            outcome: .failure(.operationFailed))
        #expect(failedFinished)
        #expect(session.currentIndex == 1)
    }

    @Test("Same text in another field does not reuse old range history")
    func identicalTextElsewhereResetsHistory() throws {
        var session = try appliedSession()
        #expect(session.versionCount == 2)

        let moved = EditSession.SelectionEvidence(
            text: "result",
            target: targetB,
            range: .init(location: 40, length: 6))
        let adoptionFailure = session.adopt(.selection(moved))
        #expect(adoptionFailure == nil)

        #expect(session.versionCount == 0)
        #expect(session.currentIndex == 0)
    }

    @Test("Cancellation records its boundary without advancing history")
    func cancellationBoundaryDoesNotCommit() throws {
        var session = selectionSession()
        _ = try generationRequest(from: &session)

        let outcome = session.cancel(at: .generation)
        #expect(outcome == .cancelled(.generation))
        #expect(session.stage == .idle)
        #expect(session.versionCount == 0)
    }

    @Test("Changing scope discards history before it can target the wrong span")
    func scopeChangesInvalidateHistory() throws {
        var selection = try appliedSession()
        selection.setScope(.document)
        #expect(selection.versionCount == 0)
        #expect(selection.currentIndex == 0)
        #expect(selection.navigation(to: 0) == nil)

        var document = EditSession(ownPid: 99)
        _ = document.begin(with: .noSelection(targetA))
        try applyDocumentResult("new document", currentText: "original document", to: &document)
        #expect(document.versionCount == 2)
        document.setScope(.selection)
        #expect(document.versionCount == 0)
        #expect(document.currentIndex == 0)
        #expect(document.navigation(to: 0) == nil)
    }

    @MainActor
    @Test("Pasteboard restoration requires exact operation ownership")
    func pasteboardOwnershipIsLocal() throws {
        let name = NSPasteboard.Name("mancia-edit-safety-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.clearContents() }

        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("borrowed", forType: .string)
        let ownership = PasteboardOwnership.claim(pasteboard)
        #expect(snapshot.restore(to: pasteboard, ifOwnedBy: ownership))
        #expect(pasteboard.string(forType: .string) == "before")

        pasteboard.clearContents()
        pasteboard.setString("borrowed again", forType: .string)
        let staleOwnership = PasteboardOwnership.claim(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)

        #expect(!snapshot.restore(to: pasteboard, ifOwnedBy: staleOwnership))
        #expect(pasteboard.string(forType: .string) == "new user copy")
    }

    @MainActor
    @Test("Clipboard copy ownership requires matching selected text evidence")
    func copyOwnershipRequiresPositiveAttribution() {
        let pasteboard = NSPasteboard(
            name: .init("mancia-copy-attribution-\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }

        pasteboard.clearContents()
        pasteboard.setString("selected", forType: .string)
        #expect(PasteboardOwnership.claimCopiedSelection(
            expectedSelectedText: "selected",
            from: pasteboard) != nil)
        #expect(PasteboardOwnership.claimCopiedSelection(
            expectedSelectedText: nil,
            from: pasteboard) == nil)
        #expect(PasteboardOwnership.claimCopiedSelection(
            expectedSelectedText: "external copy",
            from: pasteboard) == nil)
        #expect(PasteboardOwnership.claimCopiedSelection(
            expectedSelectedText: "",
            from: pasteboard) == nil)
    }

    @Test("Only the latest coordinator operation may mutate shared state")
    func coordinatorOperationEpochRejectsStaleWork() {
        var epoch = CoordinatorOperationEpoch()
        let first = epoch.advance()
        #expect(epoch.isCurrent(first))
        let second = epoch.advance()
        #expect(!epoch.isCurrent(first))
        #expect(epoch.isCurrent(second))
    }

    @Test("Mancia focus reactivates the original target instead of retargeting")
    func refreshDecisionNeverCapturesMancia() {
        #expect(SelectionRefreshDecision.decide(
            frontmostPid: 99,
            targetPid: 501,
            ownPid: 99) == .reactivateTarget)
        #expect(SelectionRefreshDecision.decide(
            frontmostPid: 501,
            targetPid: 501,
            ownPid: 99) == .reuseTarget)
        #expect(SelectionRefreshDecision.decide(
            frontmostPid: 777,
            targetPid: 501,
            ownPid: 99) == .captureFrontmost)
    }

    @MainActor
    @Test("Applied presentation preserves the Custom draft for the session")
    func customDraftSurvivesAppliedPresentation() {
        let model = PanelModel()
        model.selectCustomInstruction()
        model.instruction = "keep this draft"

        model.restoreButtonsAfterApply()

        #expect(model.actionChoice == .preset(.improve))
        #expect(model.instruction == "keep this draft")
        model.reset(hasSelection: true, charCount: 10)
        #expect(model.instruction.isEmpty)
    }

    @Test("Document generation and replacement approvals are separate policies")
    func approvalPoliciesAreSeparate() {
        #expect(ApplyConfirmation.requiresGenerationApproval(isWholeDocument: true))
        #expect(!ApplyConfirmation.requiresGenerationApproval(isWholeDocument: false))
        #expect(ApplyConfirmation.requiresReplacementApproval(
            isWholeDocument: true,
            userOptedIn: true))
        #expect(!ApplyConfirmation.requiresReplacementApproval(
            isWholeDocument: true,
            userOptedIn: false))
    }

    private func selectionSession() -> EditSession {
        var session = EditSession(ownPid: 99)
        _ = session.begin(with: .selection(.init(
            text: "original",
            target: targetA,
            range: range)))
        return session
    }

    private func generationRequest(
        from session: inout EditSession
    ) throws -> EditSession.GenerationRequest {
        guard case .send(let request) = session.requestGeneration() else {
            throw TestFailure("expected generation request")
        }
        return request
    }

    private func applyPlan(
        from session: inout EditSession,
        output: String
    ) throws -> EditSession.ApplyPlan {
        let request = try generationRequest(from: &session)
        let result = EditSession.GeneratedResult(output: output, for: request)
        guard case .apply(let plan) = session.consider(
            result,
            replacementConfirmationRequired: false)
        else {
            throw TestFailure("expected apply plan")
        }
        return plan
    }

    private func appliedSession() throws -> EditSession {
        var session = selectionSession()
        let plan = try applyPlan(from: &session, output: "result")
        let evidence = EditSession.AppliedEvidence(
            text: "result",
            target: .selection(
                target: targetA,
                range: .init(location: range.location, length: 6)))
        guard session.finishApply(plan, outcome: .applied(evidence)) else {
            throw TestFailure("expected verified apply")
        }
        return session
    }

    private func applyDocumentResult(
        _ output: String,
        currentText: String,
        to session: inout EditSession
    ) throws {
        guard session.requestGeneration() == .requestDocumentApproval,
              case .captureDocument = session.approveDocumentGeneration(),
              case .send(let request) = session.acceptDocumentCapture(
                .captured(text: currentText, target: targetA)),
              case .apply(let plan) = session.consider(
                .init(output: output, for: request),
                replacementConfirmationRequired: false)
        else {
            throw TestFailure("expected document apply plan")
        }
        guard session.finishApply(
            plan,
            outcome: .applied(.init(
                text: output,
                target: .document(targetA))))
        else {
            throw TestFailure("expected verified document apply")
        }
    }
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
