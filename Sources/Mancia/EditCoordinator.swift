import AppKit

/// Orchestrates a cyclical edit session: capture selection → show the ribbon →
/// run provider → apply inline → undo or run further actions, until the
/// user closes the session. Owns the ribbon and the
/// in-flight task. The ribbon stays visible throughout — synthetic keystrokes
/// are posted to the target app's pid, so they can't be swallowed by it.
@MainActor
final class EditCoordinator {
    private let provider: LLMProvider
    private let settings: AppSettings
    private let model = PanelModel()
    /// The ribbon, built on first use and kept for the app's lifetime so
    /// re-opening a session doesn't tear down and re-create a window
    /// mid-animation.
    private lazy var ribbon: RibbonWindow = {
        let ribbon = RibbonWindow(model: model)
        ribbon.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        ribbon.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        return ribbon
    }()

    private var capture: SelectionCaptureResult?
    private var currentTask: Task<Void, Never>?
    /// True while the selection is being captured after an instant show; an
    /// action fired during this window is queued in `pendingAction`.
    private var capturing = false
    private var pendingAction: EditAction?
    private var pendingNote: String?
    /// The post-apply auto-close beat (hybrid behavior). Cancelled on any panel
    /// key press so the user can keep editing.
    private var autoCloseTask: Task<Void, Never>?
    /// Iteration history: versions[0] is the session original (reset when the
    /// user makes a fresh selection or manual edit mid-session), followed by
    /// one entry per applied result.
    private var versions: [String] = []
    /// Which version the document currently shows.
    private var currentIndex = 0
    /// Guards against overlapping version-restore keystroke sequences.
    private var navigating = false
    /// True from the moment a session begins starting until the panel closes,
    /// so a repeated hotkey/menu trigger can't spawn an overlapping capture.
    private var sessionActive = false
    /// A completed whole-document result awaiting explicit confirmation before
    /// it overwrites the document (`.confirm` phase).
    private var pendingApply: (output: String, baseline: String)?
    /// Wired by AppDelegate; invoked by the ribbon's ⌘, shortcut.
    var onOpenSettings: (() -> Void)?

    init(provider: LLMProvider, settings: AppSettings) {
        self.provider = provider
        self.settings = settings
        wire()
    }

    private func wire() {
        model.onPerform = { [weak self] action, note in self?.perform(action, note: note) }
        model.onUndoVersion = { [weak self] in self?.undoLastVersion() ?? false }
        model.onRetry = { [weak self] in self?.retry() }
        model.onConfirmApply = { [weak self] in self?.confirmApply() }
        model.onCancelRun = { [weak self] in self?.cancelRun() }
        model.onCancel = { [weak self] in self?.cancel() }
    }

    /// Entry point from hotkey or menu. Starts a fresh session. Ignores
    /// re-triggers while a session is already active, so overlapping capture
    /// sequences can't clobber each other's pasteboard/keystroke state.
    ///
    /// The ribbon appears immediately (perceived latency ≈ 0); the selection is
    /// captured in the background. If the user fires Improve/Enter before the
    /// capture completes, the action is queued and runs the moment text is ready.
    func start() {
        guard !sessionActive else { ribbon.focus(); return }
        guard ensureAccessibility() else { return }
        sessionActive = true
        currentTask?.cancel()
        autoCloseTask?.cancel()
        autoCloseTask = nil
        pendingAction = nil
        pendingNote = nil
        pendingApply = nil
        capture = nil
        versions = []
        currentIndex = 0
        navigating = false
        capturing = true
        // Optimistically assume a selection until capture proves otherwise;
        // the status line reads "Reading selection…" until it resolves.
        model.reset(hasSelection: true, charCount: 0)
        model.capturing = true
        ribbon.show()
        ribbon.focus()
        warmProvider()
        currentTask = Task {
            let result = await SelectionCapture.captureSelection()
            if Task.isCancelled { return }
            self.capture = result
            self.capturing = false
            let hasSelection = result.text != nil
            model.capturing = false
            model.hasSelection = hasSelection
            model.selectionCharCount = result.text?.count ?? 0
            model.scope = hasSelection ? .selection : .document
            if let pending = pendingAction {
                let note = pendingNote
                pendingAction = nil
                pendingNote = nil
                perform(pending, note: note)
            }
        }
    }

    // MARK: - Actions

    /// How an apply cycle replaces text in the target document.
    private enum ApplyStrategy {
        /// ⌘A + ⌘V (entire-document scope; every cycle).
        case entireDocument
        /// ⌘V over the live selection (first cycle or fresh user selection).
        case liveSelection
        /// ⌘Z first (undo the previous paste, which restores and re-selects
        /// the replaced text in NSTextView-based apps), then ⌘V over it.
        case undoThenPaste
    }

    private func perform(_ action: EditAction, note: String? = nil) {
        // Fired before the background capture finished: queue it and show the
        // spinner; it runs the moment the selection is ready.
        if capturing {
            pendingAction = action
            pendingNote = note
            model.runningTitle = action.progressLabel
            model.phase = .running
            return
        }
        currentTask?.cancel()
        autoCloseTask?.cancel()
        autoCloseTask = nil
        currentTask = Task {
            let previousPhase = model.phase
            model.runningTitle = action.progressLabel
            model.phase = .running
            guard let resolved = await resolveInput() else {
                ribbon.focus()
                if !Task.isCancelled, model.phase == .running { fail("There is no text to edit.") }
                return
            }
            // Input capture may have activated the target app; retake key
            // status so Esc reaches the panel while the provider runs.
            ribbon.focus()
            let prompt: String
            do {
                try PromptGuard.validate(action: action, text: resolved.text, note: note)
                prompt = PromptBuilder.build(action: action, text: resolved.text, note: note)
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
                return
            }
            do {
                let output = try await provider.complete(prompt)
                if Task.isCancelled { return }
                guard let capture else { return }
                // Gate a whole-document overwrite behind explicit confirmation:
                // an injection-influenced or runaway result there would silently
                // replace the entire document. Selection edits apply immediately.
                if ApplyConfirmation.isRequired(
                    isWholeDocument: resolved.strategy == .entireDocument,
                    userOptedIn: settings.confirmWholeDocumentReplace
                ) {
                    presentConfirmation(output: output, baseline: resolved.text)
                    return
                }
                // Apply immediately. Keystrokes are posted to the target
                // app's pid, so the panel stays visible throughout.
                await applyResolved(output: output, strategy: resolved.strategy, capture: capture)
                if Task.isCancelled { return }
                dodgeAppliedText()
                recordApplied(output: output, baseline: resolved.text)
            } catch is CancellationError {
                if model.phase == .running { model.phase = previousPhase }
                return
            } catch {
                if Task.isCancelled { return }
                fail(error.localizedDescription)
            }
        }
    }

    /// Perform the actual text replacement for a resolved strategy.
    private func applyResolved(output: String, strategy: ApplyStrategy, capture: SelectionCaptureResult) async {
        switch strategy {
        case .entireDocument:
            await SelectionCapture.apply(text: output, to: capture, entireDocument: true)
        case .liveSelection:
            await SelectionCapture.apply(text: output, to: capture, entireDocument: false)
        case .undoThenPaste:
            await SelectionCapture.undo(in: capture)
            await SelectionCapture.apply(text: output, to: capture, entireDocument: false)
        }
    }

    /// Where the paste left the caret, read while the target app still owns
    /// focus — once the lane retakes key the system-wide focused element is
    /// the Direction field and the caret can no longer be read. The lane
    /// steps off the updated text if it landed on it, so every apply path
    /// calls this before refocusing the ribbon.
    private func dodgeAppliedText() {
        ribbon.avoidUpdatedText(caretRect: SelectionCapture.selectionScreenRect())
    }

    /// Record an applied result in the iteration history and move to the applied
    /// phase (shared by the immediate and confirmed apply paths).
    private func recordApplied(output: String, baseline: String) {
        // Record the iteration: drop any forward history, then append.
        if versions.isEmpty { versions = [baseline] }
        versions = Array(versions.prefix(currentIndex + 1))
        versions.append(output)
        currentIndex = versions.count - 1
        syncIterationState()
        model.restoreDefaultAction()
        model.phase = .applied
        ribbon.focus()
        scheduleAutoCloseIfHybrid()
    }

    // MARK: - Whole-document confirmation

    /// Pause a completed whole-document result in the confirm phase, surfacing
    /// the size change so the user can decide before overwriting everything.
    private func presentConfirmation(output: String, baseline: String) {
        pendingApply = (output, baseline)
        model.pendingOriginalCharCount = baseline.count
        model.pendingResultCharCount = output.count
        model.pendingResultPreview = output
        model.phase = .confirm
        ribbon.focus()
    }

    /// Apply the pending whole-document replacement after the user confirmed.
    /// Commit into `.running` before the destructive ⌘A+⌘V so the confirm
    /// affordance can't imply "nothing has happened yet" mid-overwrite; this
    /// mirrors the immediate apply path, which is `.running` while it pastes.
    private func confirmApply() {
        guard model.phase == .confirm, let capture, let pending = pendingApply else { return }
        pendingApply = nil
        model.pendingResultPreview = ""
        model.runningTitle = "Replacing document"
        model.phase = .running
        currentTask?.cancel()
        currentTask = Task {
            await SelectionCapture.apply(text: pending.output, to: capture, entireDocument: true)
            if Task.isCancelled { return }
            dodgeAppliedText()
            recordApplied(output: pending.output, baseline: pending.baseline)
        }
    }

    /// Determine this cycle's input text and apply strategy.
    ///
    /// - Document scope: if the session started without selected text, first
    ///   probe for a fresh live selection. Otherwise re-capture via ⌘A+⌘C every
    ///   cycle, so manual edits the user made between cycles (and the
    ///   navigation position) are respected; text that differs from the
    ///   currently shown version becomes the new session baseline.
    /// - Selection scope, first cycle: the text captured when the session
    ///   started; the original selection is still live in the target app.
    /// - Selection scope, later cycles: probe with a fresh ⌘C — a new user
    ///   selection becomes the new session baseline. Otherwise the input is
    ///   versions[currentIndex] (what the document shows), replaced via
    ///   undo-then-paste.
    private func resolveInput() async -> (text: String, strategy: ApplyStrategy)? {
        // Ahead of both scope branches: a run belongs to the app the user is
        // actually in, and neither branch can tell that the session's target
        // went stale underneath it.
        if let retargeted = await retargetToFrontmostApp() { return retargeted }
        guard let capture else { return nil }
        if model.scope == .document {
            if !model.hasSelection,
               let fresh = await SelectionCapture.captureFreshSelection(from: capture),
               !fresh.isEmpty,
               versions.isEmpty || fresh != versions[currentIndex] {
                adoptFreshSelection(fresh)
                resetBaseline(to: fresh)
                return (fresh, .liveSelection)
            }
            let text = await SelectionCapture.captureEntireDocument(from: capture)
            guard let text, !text.isEmpty else { return nil }
            if versions.isEmpty || text != versions[currentIndex] {
                resetBaseline(to: text)
            }
            return (text, .entireDocument)
        }
        if versions.isEmpty {
            guard let text = capture.text, !text.isEmpty else { return nil }
            return (text, .liveSelection)
        }
        // Later cycle: check for a fresh user selection first.
        if let fresh = await SelectionCapture.captureFreshSelection(from: capture), !fresh.isEmpty {
            // Unconditional, and ahead of the baseline check: even text
            // identical to the last result can have been re-selected somewhere
            // else, and the Target chip has to describe the span this run will
            // actually send, not the one the session opened on.
            adoptFreshSelection(fresh)
            if fresh != versions[currentIndex] {
                // A genuinely new selection starts a new session baseline.
                resetBaseline(to: fresh)
            }
            return (fresh, .liveSelection)
        }
        let text = versions[currentIndex]
        guard !text.isEmpty else { return nil }
        return (text, .undoThenPaste)
    }

    /// A freshly captured live selection becomes the session's target.
    ///
    /// Every place that promotes one — a document-scope session finding a
    /// selection, a later selection-scope cycle finding a new one, and a
    /// re-target to another app — has to say the same thing, or the Target
    /// chip goes on describing the span the session opened on while the run
    /// sends a different one. Callers own the baseline decision; this only
    /// states what is now selected.
    ///
    /// The target app owns focus at every call site, which is what makes the
    /// selection's bounds readable here.
    private func adoptFreshSelection(_ text: String) {
        model.hasSelection = true
        model.selectionCharCount = text.count
        model.scope = .selection
        ribbon.noteSelectionMoved(SelectionCapture.selectionScreenRect())
    }

    /// The user moved to a different app and selected text there while the
    /// lane was up.
    ///
    /// `capture` — and with it the pid every synthetic keystroke is posted to
    /// — is frozen when the session starts, so without this the run would pull
    /// the *original* app forward and edit whatever was still selected in it,
    /// with nothing on screen saying so.
    ///
    /// Re-targeting always goes through `resetBaseline`, which clears the
    /// version history. That history describes edits Mancia made in the old
    /// app; replaying it through `.undoThenPaste` would post ⌘Z into an app
    /// Mancia never pasted into and undo an edit of the user's own.
    ///
    /// Only a live selection re-targets. With nothing selected in the new app
    /// there is no evidence about what the user wants edited, so the session
    /// stays where it is rather than guessing at a whole-document rewrite.
    private func retargetToFrontmostApp() async -> (text: String, strategy: ApplyStrategy)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != capture?.targetApp?.processIdentifier,
              // Never re-target onto Mancia. The lane takes key without
              // activating the app, so this is normally impossible — but ⌘,
              // and the permission alert both make Mancia frontmost, and
              // posting ⌘C to ourselves would capture nothing and strand the
              // session on the wrong pid.
              frontmost.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        // A full capture rather than a bare probe: the new app needs its own
        // pasteboard snapshot to restore after the paste, and its own
        // `targetApp` for every keystroke from here on.
        let result = await SelectionCapture.captureSelection()
        guard let text = result.text, !text.isEmpty else { return nil }
        capture = result
        adoptFreshSelection(text)
        resetBaseline(to: text)
        return (text, .liveSelection)
    }

    /// A fresh selection or manual edit becomes the new session baseline.
    private func resetBaseline(to text: String) {
        versions = [text]
        currentIndex = 0
        syncIterationState()
    }

    private func syncIterationState() {
        model.versionCount = versions.count
        model.currentIndex = currentIndex
    }

    /// Replace the document text with versions[index].
    ///
    /// - Selection scope: ⌘Z (undo of the outstanding paste restores and
    ///   re-selects the replaced region in NSTextView-based apps) followed by
    ///   ⌘V with versions[index] — always undo-then-paste, including for
    ///   index 0, so exactly one paste stays outstanding.
    /// - Document scope: ⌘A + ⌘V with versions[index], which stays correct
    ///   even when the user manually edited between cycles.
    @discardableResult
    private func restoreVersion(at index: Int) -> Bool {
        guard let capture, model.phase == .applied, !navigating,
              index >= 0, index < versions.count, index != currentIndex else { return false }
        autoCloseTask?.cancel()
        autoCloseTask = nil
        navigating = true
        currentIndex = index
        syncIterationState()
        currentTask = Task {
            defer { navigating = false }
            let text = versions[index]
            if model.scope == .document {
                await SelectionCapture.apply(text: text, to: capture, entireDocument: true)
            } else {
                await SelectionCapture.undo(in: capture)
                await SelectionCapture.apply(text: text, to: capture, entireDocument: false)
            }
            dodgeAppliedText()
            ribbon.focus()
        }
        return true
    }

    /// ⌘Z walks backward through Mancia's applied versions. For selection
    /// edits `restoreVersion` still leaves exactly one target-app paste on its
    /// undo stack, preserving the existing safe replacement behavior.
    private func undoLastVersion() -> Bool {
        restoreVersion(at: currentIndex - 1)
    }

    /// Retry after an error by running what the ribbon currently describes.
    /// Switching to Custom first therefore retries with the newly typed request;
    /// hidden draft text never rides along with a preset.
    private func retry() {
        model.runPrimary()
    }

    /// Stop the in-flight action but keep the session open.
    private func cancelRun() {
        // While still capturing, the "in-flight" work is only the queued
        // action — dropping it must NOT cancel the capture task, or the session
        // would wedge with `capturing` stuck true. Let the capture finish.
        if capturing {
            pendingAction = nil
            pendingNote = nil
            model.phase = .idle
            ribbon.focus()
            return
        }
        currentTask?.cancel()
        currentTask = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        // Discard any result awaiting confirmation and return to a resting state.
        pendingApply = nil
        model.pendingResultPreview = ""
        model.phase = versions.count > 1 ? .applied : .idle
        ribbon.focus()
    }

    /// Retake key status for the panel if a session is on screen — used when
    /// the Settings window closes after stealing key from the panel (⌘,).
    func refocusPanel() {
        ribbon.focus()
    }

    /// Close the session (Esc / Done), keeping the document as shown.
    private func cancel() {
        currentTask?.cancel()
        currentTask = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        pendingApply = nil
        // The review gate's preview is the whole generated document. Esc is a
        // decision like any other, so it discards the text on the same beat
        // confirming or declining does — not at the next session's `reset`.
        model.pendingResultPreview = ""
        sessionActive = false
        ribbon.close()
        warmProviderAfterClose()
    }

    private func warmProvider() {
        guard let provider = provider as? WarmableLLMProvider else { return }
        Task { await provider.prepareForPanel() }
    }

    private func warmProviderAfterClose() {
        guard let provider = provider as? WarmableLLMProvider else { return }
        Task { await provider.panelDidClose() }
    }

    // MARK: - Post-apply behavior

    /// After an edit lands, hybrid behavior flashes completion then auto-closes
    /// the panel after a short beat. `stayOpen` leaves it up for another action
    /// or ⌘Z.
    private func scheduleAutoCloseIfHybrid() {
        autoCloseTask?.cancel()
        guard settings.postApplyBehavior == .hybrid else {
            autoCloseTask = nil
            return
        }
        autoCloseTask = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if Task.isCancelled { return }
            guard model.phase == .applied else { return }
            // A keypress is not the only sign the user is still working. The
            // lane holds key without activating Mancia, so losing it during
            // the beat means the user clicked back into the host app — in a
            // session that has just applied an edit, almost always to select
            // the next span. Closing under them would end the session they
            // are still in, so the beat is abandoned rather than rescheduled;
            // Esc and Done still close.
            guard ribbon.isKey else { return }
            cancel()
        }
    }

    /// Handle a key press routed to the panel. Always cancels the post-apply
    /// auto-close beat so the user can keep editing. Version undo is a key
    /// equivalent handled by `KeyablePanel`, after the instruction field's own
    /// undo stack has had first refusal. Returns whether the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        if model.phase == .confirm {
            // Return / keypad Enter confirms the pending whole-document replace.
            if event.keyCode == 36 || event.keyCode == 76 {
                confirmApply()
                return true
            }
            return false
        }
        return false
    }

    private func fail(_ message: String) {
        model.errorText = message
        model.phase = .error
        ribbon.focus()
    }

    // MARK: - Accessibility

    private func ensureAccessibility() -> Bool {
        if Permissions.isAccessibilityTrusted { return true }
        Permissions.requestAccessibility()
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = "Mancia needs Accessibility access to read your selection and paste results.\n\nEnable it in System Settings ▸ Privacy & Security ▸ Accessibility, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
        return false
    }
}
