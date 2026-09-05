import Foundation

/// Pure policy for target consent, stale-result rejection, and verified history.
struct EditSession: Equatable {
    enum Scope: Equatable { case selection, document }

    /// Supplements the panel's broad phase with the active safety boundary.
    enum Stage: Equatable {
        case idle
        case awaitingDocumentApproval
        case capturingDocument
        case generating
        case awaitingReplacementApproval
        case applying
        case navigating
    }

    /// Stable identity for one editable Accessibility element.
    struct TargetID: Equatable, Hashable {
        var pid: pid_t
        var elementIdentifier: UInt64?
    }

    struct TextRange: Equatable, Hashable {
        var location: Int
        var length: Int

        var isValid: Bool { location >= 0 && length > 0 }
    }

    /// `range` may be absent in capture results, but provider work and history
    /// require it because replacement must be able to reselect the exact span.
    struct SelectionEvidence: Equatable {
        var text: String
        var target: TargetID
        var range: TextRange?
    }

    /// A proved empty selection is distinct from a failed or ambiguous read.
    enum CaptureEvidence: Equatable {
        case selection(SelectionEvidence)
        case noSelection(TargetID)
        case uncertain(targetPid: pid_t?)
    }

    enum DocumentCapture: Equatable {
        case captured(text: String, target: TargetID)
        case uncertain
    }

    enum TargetEvidence: Equatable {
        case selection(target: TargetID, range: TextRange?)
        case document(TargetID)
    }

    struct Baseline: Equatable {
        var text: String
        var target: TargetEvidence
        var scope: Scope
        fileprivate var revision: UInt64
    }

    struct GenerationRequest: Equatable {
        fileprivate var id: UInt64
        var baseline: Baseline

        var text: String { baseline.text }
    }

    /// Provider output remains tied to the baseline and target that produced it.
    struct GeneratedResult: Equatable {
        var output: String
        var request: GenerationRequest

        init(output: String, for request: GenerationRequest) {
            self.output = output
            self.request = request
        }

        var baseline: Baseline { request.baseline }
    }

    struct ApplyPlan: Equatable {
        var result: GeneratedResult

        var target: TargetEvidence { result.baseline.target }
        var isWholeDocument: Bool {
            if case .document = target { return true }
            return false
        }
    }

    struct AppliedEvidence: Equatable {
        var text: String
        var target: TargetEvidence
    }

    enum Failure: Error, Equatable {
        case busy
        case uncertainCapture
        case noSelection
        case emptyInput
        case emptyResult
        case invalidTarget
        case missingReselectionMetadata
        case targetChanged
        case staleResult
        case invalidTransition
        case operationFailed
    }

    enum CancellationBoundary: Equatable {
        case beforeGeneration
        case generation
        case beforeApply
        case apply
        case navigation
    }

    enum Outcome: Equatable {
        case applied(AppliedEvidence)
        case retained
        case cancelled(CancellationBoundary)
        case failure(Failure)
    }

    enum GenerationDecision: Equatable {
        case requestDocumentApproval
        case captureDocument(TargetID)
        case send(GenerationRequest)
        case failure(Failure)
    }

    enum ResultDecision: Equatable {
        case retained
        case requestReplacementApproval(GeneratedResult)
        case apply(ApplyPlan)
        case failure(Failure)
    }

    struct Version: Equatable {
        var text: String
        fileprivate(set) var target: TargetEvidence
    }

    struct NavigationTarget: Equatable {
        var text: String
        var target: TargetID
        var range: TextRange?
        var scope: Scope
    }

    /// The coordinator must reselect and verify `current` before replacing it.
    /// Creating a plan does not move `currentIndex`.
    struct NavigationPlan: Equatable {
        fileprivate var id: UInt64
        var fromIndex: Int
        var toIndex: Int
        var current: NavigationTarget
        var replacement: String
    }

    private enum CurrentTarget: Equatable {
        case selection(SelectionEvidence)
        case noSelection(TargetID)
        case document(text: String, target: TargetID)
        case uncertain(targetPid: pid_t?)
    }

    private let ownPid: pid_t
    private var current: CurrentTarget = .uncertain(targetPid: nil)
    private var revision: UInt64 = 0
    private var nextID: UInt64 = 0
    private var pendingGeneration: GenerationRequest?
    private var pendingResult: GeneratedResult?
    private var pendingNavigation: NavigationPlan?

    private(set) var scope: Scope = .selection
    private(set) var stage: Stage = .idle
    private(set) var versions: [Version] = []
    private(set) var currentIndex = 0

    init(ownPid: pid_t) {
        self.ownPid = ownPid
    }

    var versionCount: Int { versions.count }
    var versionTexts: [String] { versions.map(\.text) }

    /// `nil` tells the coordinator not to silently choose document scope.
    var suggestedScope: Scope? {
        switch current {
        case .selection: return .selection
        case .noSelection, .document: return .document
        case .uncertain: return nil
        }
    }

    @discardableResult
    mutating func begin(with capture: CaptureEvidence) -> Failure? {
        revision &+= 1
        scope = {
            if case .noSelection = capture { return .document }
            return .selection
        }()
        current = .uncertain(targetPid: nil)
        versions = []
        currentIndex = 0
        invalidatePending()
        return replaceCurrent(with: capture)
    }

    /// Any scope change makes in-flight approvals and provider output stale.
    mutating func setScope(_ scope: Scope) {
        guard self.scope != scope else { return }
        self.scope = scope
        revision &+= 1
        versions = []
        currentIndex = 0
        invalidatePending()
    }

    /// Target and range identity take precedence over matching text.
    @discardableResult
    mutating func adopt(_ capture: CaptureEvidence) -> Failure? {
        let previous = current
        if let failure = replaceCurrent(with: capture) { return failure }
        guard current != previous else { return nil }
        revision &+= 1
        versions = []
        currentIndex = 0
        invalidatePending()
        return nil
    }

    /// Document scope always pauses before capture and provider send.
    mutating func requestGeneration() -> GenerationDecision {
        guard stage == .idle else { return .failure(.busy) }
        if scope == .document {
            guard currentTargetID != nil else { return .failure(captureFailure) }
            stage = .awaitingDocumentApproval
            return .requestDocumentApproval
        }

        guard case .selection(let evidence) = current else {
            return .failure(captureFailure)
        }
        guard !evidence.text.isEmpty else { return .failure(.emptyInput) }
        return startGeneration(
            text: evidence.text,
            target: .selection(target: evidence.target, range: evidence.range))
    }

    mutating func approveDocumentGeneration() -> GenerationDecision {
        guard stage == .awaitingDocumentApproval, scope == .document,
              let target = currentTargetID
        else { return .failure(.invalidTransition) }
        stage = .capturingDocument
        return .captureDocument(target)
    }

    mutating func acceptDocumentCapture(_ capture: DocumentCapture) -> GenerationDecision {
        guard stage == .capturingDocument, scope == .document,
              let approvedTarget = currentTargetID
        else { return .failure(.invalidTransition) }

        switch capture {
        case .uncertain:
            stage = .idle
            return .failure(.uncertainCapture)
        case .captured(let text, let target):
            guard target == approvedTarget, target.pid != ownPid else {
                stage = .idle
                return .failure(.targetChanged)
            }
            guard !text.isEmpty else {
                stage = .idle
                return .failure(.emptyInput)
            }
            current = .document(text: text, target: target)
            return startGeneration(text: text, target: .document(target))
        }
    }

    /// Unchanged output is retained without producing an apply plan.
    mutating func consider(
        _ result: GeneratedResult,
        replacementConfirmationRequired: Bool
    ) -> ResultDecision {
        guard stage == .generating,
              pendingGeneration == result.request,
              result.baseline.revision == revision,
              result.baseline.scope == scope
        else { return .failure(.staleResult) }

        pendingGeneration = nil
        guard !result.output.isEmpty else {
            stage = .idle
            return .failure(.emptyResult)
        }
        guard result.output != result.baseline.text else {
            stage = .idle
            return .retained
        }

        pendingResult = result
        if result.baseline.scope == .document && replacementConfirmationRequired {
            stage = .awaitingReplacementApproval
            return .requestReplacementApproval(result)
        }
        stage = .applying
        return .apply(ApplyPlan(result: result))
    }

    mutating func approveReplacement() -> ResultDecision {
        guard stage == .awaitingReplacementApproval,
              let result = pendingResult,
              result.baseline.scope == .document
        else { return .failure(.invalidTransition) }
        stage = .applying
        return .apply(ApplyPlan(result: result))
    }

    @discardableResult
    mutating func retainPendingResult() -> Outcome? {
        guard stage == .awaitingReplacementApproval, pendingResult != nil else { return nil }
        invalidatePending()
        return .retained
    }

    /// Only a matching verified apply can advance history.
    @discardableResult
    mutating func finishApply(_ plan: ApplyPlan, outcome: Outcome) -> Bool {
        guard stage == .applying, pendingResult == plan.result else { return false }
        defer { invalidatePending() }
        guard case .applied(let evidence) = outcome else { return true }
        guard appliedEvidence(evidence, matches: plan.result) else { return false }
        commitApplied(evidence, result: plan.result)
        return true
    }

    /// Navigation verifies the version currently shown and never mutates the
    /// index before the replacement is confirmed.
    mutating func navigation(to index: Int) -> NavigationPlan? {
        guard stage == .idle,
              versions.indices.contains(index), index != currentIndex,
              versions.indices.contains(currentIndex)
        else { return nil }

        let shown = versions[currentIndex]
        let currentTarget: NavigationTarget
        switch shown.target {
        case .selection(let target, let range):
            currentTarget = NavigationTarget(
                text: shown.text,
                target: target,
                range: range,
                scope: .selection)
        case .document(let target):
            currentTarget = NavigationTarget(
                text: shown.text,
                target: target,
                range: nil,
                scope: .document)
        }
        nextID &+= 1
        let plan = NavigationPlan(
            id: nextID,
            fromIndex: currentIndex,
            toIndex: index,
            current: currentTarget,
            replacement: versions[index].text)
        pendingNavigation = plan
        stage = .navigating
        return plan
    }

    @discardableResult
    mutating func finishNavigation(_ plan: NavigationPlan, outcome: Outcome) -> Bool {
        guard stage == .navigating, pendingNavigation == plan else { return false }
        defer { invalidatePending() }
        guard case .applied(let evidence) = outcome else { return true }
        guard evidence.text == plan.replacement,
              navigationEvidence(evidence, matches: plan.current)
        else { return false }

        versions[plan.toIndex].target = evidence.target
        currentIndex = plan.toIndex
        adoptAppliedEvidence(evidence)
        revision &+= 1
        return true
    }

    @discardableResult
    mutating func cancel(at boundary: CancellationBoundary) -> Outcome {
        invalidatePending()
        return .cancelled(boundary)
    }

    @discardableResult
    mutating func fail() -> Outcome {
        invalidatePending()
        return .failure(.operationFailed)
    }

    private var currentTargetID: TargetID? {
        switch current {
        case .selection(let evidence): return evidence.target
        case .noSelection(let target), .document(_, let target): return target
        case .uncertain: return nil
        }
    }

    private var captureFailure: Failure {
        switch current {
        case .uncertain: return .uncertainCapture
        case .noSelection, .document: return .noSelection
        case .selection: return .invalidTransition
        }
    }

    private mutating func replaceCurrent(with capture: CaptureEvidence) -> Failure? {
        switch capture {
        case .selection(let evidence):
            guard evidence.target.pid != ownPid else { return .invalidTarget }
            if let range = evidence.range, !range.isValid {
                return .missingReselectionMetadata
            }
            current = .selection(evidence)
        case .noSelection(let target):
            guard target.pid != ownPid else { return .invalidTarget }
            current = .noSelection(target)
        case .uncertain(let pid):
            current = .uncertain(targetPid: pid)
        }
        return nil
    }

    private mutating func startGeneration(
        text: String,
        target: TargetEvidence
    ) -> GenerationDecision {
        nextID &+= 1
        let request = GenerationRequest(
            id: nextID,
            baseline: Baseline(
                text: text, target: target, scope: scope, revision: revision))
        pendingGeneration = request
        stage = .generating
        return .send(request)
    }

    private func appliedEvidence(
        _ evidence: AppliedEvidence,
        matches result: GeneratedResult
    ) -> Bool {
        guard evidence.text == result.output else { return false }
        switch (result.baseline.target, evidence.target) {
        case (.document(let expected), .document(let actual)):
            return expected == actual
        case (
            .selection(let expectedTarget, .some(let expectedRange)),
            .selection(let actualTarget, .some(let actualRange))
        ):
            return expectedTarget == actualTarget
                && actualRange.isValid
                && actualRange.location == expectedRange.location
        default:
            return false
        }
    }

    private mutating func commitApplied(
        _ evidence: AppliedEvidence,
        result: GeneratedResult
    ) {
        revision &+= 1
        let baseline = Version(
            text: result.baseline.text,
            target: result.baseline.target)
        if versions.indices.contains(currentIndex), versions[currentIndex] == baseline {
            versions = Array(versions.prefix(currentIndex + 1))
        } else {
            versions = [baseline]
            currentIndex = 0
        }
        versions.append(Version(text: evidence.text, target: evidence.target))
        currentIndex = versions.count - 1
        adoptAppliedEvidence(evidence)
    }

    private func navigationEvidence(
        _ evidence: AppliedEvidence,
        matches expected: NavigationTarget
    ) -> Bool {
        switch (expected.scope, evidence.target) {
        case (.document, .document(let target)):
            return target == expected.target
        case (.selection, .selection(let target, .some(let range))):
            return target == expected.target
                && range.isValid
                && range.location == expected.range?.location
        default:
            return false
        }
    }

    private mutating func adoptAppliedEvidence(_ evidence: AppliedEvidence) {
        switch evidence.target {
        case .selection(let target, let range):
            current = .selection(
                SelectionEvidence(text: evidence.text, target: target, range: range))
        case .document(let target):
            current = .document(text: evidence.text, target: target)
        }
    }

    private mutating func invalidatePending() {
        pendingGeneration = nil
        pendingResult = nil
        pendingNavigation = nil
        stage = .idle
    }
}
