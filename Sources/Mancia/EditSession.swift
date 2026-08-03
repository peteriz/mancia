import Foundation

/// Every rule about which text an edit cycle sends to the provider and how the
/// result goes back into the document.
///
/// Pure and free of AppKit, so every branch is unit-testable — the same bargain
/// `RibbonPlacement` and `ApplyConfirmation` already make. `EditCoordinator`
/// owns the ribbon, the tasks and the pasteboard mechanism; this owns the
/// decisions, which is the half that used to be reachable only by posting real
/// ⌘C/⌘A/⌘V/⌘Z into another process.
///
/// The shape is a step machine rather than one function because resolving a
/// cycle is a *conversation*: which probe runs next depends on the last answer.
/// The coordinator asks for a `Step`, goes and finds out, and reports back an
/// `Observation`. Ordering therefore lives here, where it can be asserted on —
/// and the ordering is load-bearing. A run belongs to the app the user is
/// actually in, so the frontmost check comes ahead of both scope branches; and
/// a fresh selection is adopted ahead of the baseline check, because text
/// identical to the last result can still have been re-selected somewhere else.
///
/// Scope and `hasSelection` are inputs rather than state: the user owns them
/// through ⌘T and the Target menu, so `PanelModel` stays their source of truth
/// and each resolution is told what they currently are.
struct EditSession: Equatable {
    /// How an apply cycle replaces text in the target document.
    enum ApplyStrategy: Equatable {
        /// ⌘A + ⌘V (entire-document scope; every cycle).
        case entireDocument
        /// ⌘V over the live selection (first cycle or fresh user selection).
        case liveSelection
        /// ⌘Z first (undo the previous paste, which restores and re-selects
        /// the replaced text in NSTextView-based apps), then ⌘V over it.
        case undoThenPaste
    }

    /// Which span the cycle is aimed at. Mirrors `PanelModel.Scope`, kept
    /// separate so this module doesn't depend on the view's state.
    enum Scope: Equatable { case selection, document }

    /// A resolved cycle: the text to send, how to put the result back, and the
    /// side effects the coordinator still has to perform.
    struct Run: Equatable {
        var text: String
        var strategy: ApplyStrategy
        /// The session is now aimed at a freshly captured live selection, so
        /// the coordinator re-states the target and tells the lane the work
        /// moved. Note this can be true for text identical to the last result.
        var adoptedSelection: Bool
        /// The run re-targeted to another app, so the coordinator swaps in the
        /// capture it just took — that capture carries the new pid every
        /// keystroke is posted to *and* the new app's pasteboard snapshot.
        var committedNewTarget: Bool
    }

    /// What the core needs the coordinator to go and find out.
    /// What the session needs next. Each case either asks the coordinator to
    /// go and find something out, or ends the resolution.
    enum Step: Equatable {
        /// Which app is the user actually in? `capture` — and with it the pid
        /// every synthetic keystroke is posted to — is frozen when the session
        /// starts, so a session that never asked would pull the *original* app
        /// forward and edit whatever was still selected in it, with nothing on
        /// screen saying so.
        case probeFrontmost
        /// Take a full capture in the app the user moved to.
        case captureNewTarget
        /// ⌘C: has the user selected something since the session opened?
        case probeFreshSelection
        /// ⌘A + ⌘C: read the whole document, so manual edits made between
        /// cycles are respected.
        case captureDocument
        /// Resolved: send this text and put the result back this way.
        case run(Run)
        /// Nothing to send — there is no evidence about what the user wants
        /// edited, so the cycle does nothing rather than guess.
        case abort
    }

    /// What the coordinator found out.
    enum Observation: Equatable {
        case start(scope: Scope, hasSelection: Bool)
        case frontmost(pid: pid_t?)
        case newTarget(text: String?, pid: pid_t?)
        case freshSelection(String?)
        case document(String?)
    }

    /// Which probe is outstanding. A fresh-selection probe means different
    /// things in the two branches that issue one, so the answer needs to know
    /// which question it is answering.
    private enum Pending: Equatable {
        case none
        /// Document scope with nothing selected, looking for a live selection
        /// to switch the session over to.
        case documentSelection
        /// A later selection-scope cycle, looking for a new user selection.
        case laterSelection
    }

    /// Mancia's own pid. The lane takes key without activating the app, so the
    /// frontmost app is normally the host — but ⌘, and the permission alert
    /// both make Mancia frontmost, and re-targeting onto ourselves would
    /// capture nothing and strand the session on the wrong pid.
    private let ownPid: pid_t

    /// Iteration history: `versions[0]` is the session original (reset when the
    /// user makes a fresh selection or manual edit mid-session), followed by
    /// one entry per applied result.
    private(set) var versions: [String] = []
    /// Which version the document currently shows.
    private(set) var currentIndex = 0

    /// The text captured when the session opened, which the first selection
    /// cycle sends — the original selection is still live in the target app.
    private var originalSelection: String?
    /// The pid the session is aimed at, compared against the frontmost app to
    /// notice the user moving to another app mid-session.
    private var targetPid: pid_t?

    private var scope: Scope = .selection
    private var hasSelection = true
    private var pending: Pending = .none

    init(ownPid: pid_t) {
        self.ownPid = ownPid
    }

    var versionCount: Int { versions.count }

    // MARK: - Session lifecycle

    /// Start a fresh session. Called twice per session: once when the lane
    /// opens, and again when the background capture lands and can say what was
    /// selected and which app owns it.
    mutating func begin(capturedText: String?, targetPid: pid_t?) {
        versions = []
        currentIndex = 0
        originalSelection = capturedText
        self.targetPid = targetPid
        pending = .none
    }

    // MARK: - Resolving a cycle

    /// Advance the resolution by one step. Every path either asks for exactly
    /// one more observation or finishes, and no observation returns the step
    /// that produced it, so a driver loop always terminates.
    mutating func next(after observation: Observation) -> Step {
        switch observation {
        case .start(let scope, let hasSelection):
            self.scope = scope
            self.hasSelection = hasSelection
            pending = .none
            // Ahead of both scope branches: a run belongs to the app the user
            // is actually in, and neither branch can tell that the session's
            // target went stale underneath it.
            return .probeFrontmost

        case .frontmost(let pid):
            guard let pid, pid != targetPid, pid != ownPid else { return resolveInScope() }
            // A full capture rather than a bare probe: the new app needs its
            // own pasteboard snapshot to restore after the paste, and its own
            // target for every keystroke from here on.
            return .captureNewTarget

        case .newTarget(let text, let pid):
            // Only a live selection re-targets. With nothing selected in the
            // new app there is no evidence about what the user wants edited,
            // so the session stays where it is rather than guessing at a
            // whole-document rewrite.
            guard let text, !text.isEmpty else { return resolveInScope() }
            targetPid = pid
            // Re-targeting always resets the baseline, which clears the version
            // history. That history describes edits Mancia made in the old app;
            // replaying it through `.undoThenPaste` would post ⌘Z into an app
            // Mancia never pasted into and undo an edit of the user's own.
            resetBaseline(to: text)
            return .run(Run(
                text: text, strategy: .liveSelection,
                adoptedSelection: true, committedNewTarget: true))

        case .freshSelection(let fresh):
            let pending = self.pending
            self.pending = .none
            switch pending {
            case .documentSelection:
                guard let fresh, !fresh.isEmpty,
                      versions.isEmpty || fresh != versions[currentIndex]
                else { return .captureDocument }
                resetBaseline(to: fresh)
                return .run(Run(
                    text: fresh, strategy: .liveSelection,
                    adoptedSelection: true, committedNewTarget: false))

            case .laterSelection:
                if let fresh, !fresh.isEmpty {
                    // Adoption is unconditional, and ahead of the baseline
                    // check: even text identical to the last result can have
                    // been re-selected somewhere else, and the Target chip has
                    // to describe the span this run will actually send.
                    if fresh != versions[currentIndex] {
                        // A genuinely new selection starts a new baseline.
                        resetBaseline(to: fresh)
                    }
                    return .run(Run(
                        text: fresh, strategy: .liveSelection,
                        adoptedSelection: true, committedNewTarget: false))
                }
                let text = versions[currentIndex]
                guard !text.isEmpty else { return .abort }
                return .run(Run(
                    text: text, strategy: .undoThenPaste,
                    adoptedSelection: false, committedNewTarget: false))

            case .none:
                return .abort
            }

        case .document(let text):
            guard let text, !text.isEmpty else { return .abort }
            // Captured text that differs from the currently shown version is a
            // manual edit the user made between cycles, and becomes the new
            // session baseline.
            if versions.isEmpty || text != versions[currentIndex] {
                resetBaseline(to: text)
            }
            return .run(Run(
                text: text, strategy: .entireDocument,
                adoptedSelection: false, committedNewTarget: false))
        }
    }

    /// The two scope branches, reached once the target has been settled.
    private mutating func resolveInScope() -> Step {
        if scope == .document {
            // A session that originally found no selection probes for a live
            // one before falling back to re-capturing the whole document.
            if !hasSelection {
                pending = .documentSelection
                return .probeFreshSelection
            }
            return .captureDocument
        }
        if versions.isEmpty {
            guard let text = originalSelection, !text.isEmpty else { return .abort }
            return .run(Run(
                text: text, strategy: .liveSelection,
                adoptedSelection: false, committedNewTarget: false))
        }
        pending = .laterSelection
        return .probeFreshSelection
    }

    // MARK: - History

    /// Record an applied result: drop any forward history, then append.
    mutating func recordApplied(output: String, baseline: String) {
        if versions.isEmpty { versions = [baseline] }
        versions = Array(versions.prefix(currentIndex + 1))
        versions.append(output)
        currentIndex = versions.count - 1
    }

    /// Move the document to `versions[index]`.
    ///
    /// - Selection scope: ⌘Z (undo of the outstanding paste restores and
    ///   re-selects the replaced region in NSTextView-based apps) followed by
    ///   ⌘V — always undo-then-paste, including for index 0, so exactly one
    ///   paste stays outstanding.
    /// - Document scope: ⌘A + ⌘V, which stays correct even when the user
    ///   manually edited between cycles.
    ///
    /// Returns `nil` when the index names nowhere to go.
    mutating func navigate(to index: Int, scope: Scope) -> Run? {
        guard index >= 0, index < versions.count, index != currentIndex else { return nil }
        currentIndex = index
        return Run(
            text: versions[index],
            strategy: scope == .document ? .entireDocument : .undoThenPaste,
            adoptedSelection: false, committedNewTarget: false)
    }

    /// A fresh selection or manual edit becomes the new session baseline.
    private mutating func resetBaseline(to text: String) {
        versions = [text]
        currentIndex = 0
    }
}
