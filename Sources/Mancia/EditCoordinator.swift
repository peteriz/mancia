import AppKit

/// Orchestrates a cyclical edit session: capture selection → show panel →
/// run provider → apply inline → navigate between iterations or run further
/// actions, until the user closes the session. Owns the panel and the
/// in-flight task. The panel stays visible throughout — synthetic keystrokes
/// are posted to the target app's pid, so they can't be swallowed by it.
@MainActor
final class EditCoordinator {
    private let provider: LLMProvider
    private let settings: AppSettings
    private let model = PanelModel()
    private let panel: EditPanel

    private var capture: SelectionCaptureResult?
    private var currentTask: Task<Void, Never>?
    private var lastAction: EditAction?
    /// True while the selection is being captured after an instant show; an
    /// action fired during this window is queued in `pendingAction`.
    private var capturing = false
    private var pendingAction: EditAction?
    /// The post-apply auto-close beat (hybrid behavior). Cancelled on any panel
    /// key press so the user can keep iterating.
    private var autoCloseTask: Task<Void, Never>?
    /// Iteration history: versions[0] is the session original (reset when the
    /// user makes a fresh selection or manual edit mid-session), followed by
    /// one entry per applied result.
    private var versions: [String] = []
    /// Which version the document currently shows.
    private var currentIndex = 0
    /// Guards against overlapping navigation keystroke sequences.
    private var navigating = false
    /// True from the moment a session begins starting until the panel closes,
    /// so a repeated hotkey/menu trigger can't spawn an overlapping capture.
    private var sessionActive = false
    /// A completed whole-document result awaiting explicit confirmation before
    /// it overwrites the document (`.confirm` phase).
    private var pendingApply: (output: String, baseline: String)?
    /// Wired by AppDelegate; invoked by the panel's ⌘, shortcut.
    var onOpenSettings: (() -> Void)?

    init(provider: LLMProvider, settings: AppSettings) {
        self.provider = provider
        self.settings = settings
        self.panel = EditPanel(model: model)
        wire()
    }

    private func wire() {
        model.onPerform = { [weak self] in self?.perform($0) }
        model.onNavigate = { [weak self] in self?.navigate(to: $0) }
        model.onRetry = { [weak self] in self?.retry() }
        model.onConfirmApply = { [weak self] in self?.confirmApply() }
        model.onCancelRun = { [weak self] in self?.cancelRun() }
        model.onCancel = { [weak self] in self?.cancel() }
        panel.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
    }

    /// Entry point from hotkey or menu. Starts a fresh session. Ignores
    /// re-triggers while a session is already active, so overlapping capture
    /// sequences can't clobber each other's pasteboard/keystroke state.
    ///
    /// The panel appears immediately (perceived latency ≈ 0); the selection is
    /// captured in the background. If the user fires Improve/Enter before the
    /// capture completes, the action is queued and runs the moment text is ready.
    func start() {
        guard !sessionActive else { panel.focus(); return }
        guard ensureAccessibility() else { return }
        sessionActive = true
        currentTask?.cancel()
        autoCloseTask?.cancel()
        autoCloseTask = nil
        pendingAction = nil
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
        panel.show(placement: instantPlacement())
        panel.focus()
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
                pendingAction = nil
                perform(pending)
            }
        }
    }

    /// Placement decided instantly from the Accessibility caret rect (a fast,
    /// non-polling query), so the panel never jumps after the capture completes.
    private func instantPlacement() -> EditPanel.Placement {
        if let rect = SelectionCapture.selectionScreenRect() { return .near(rect) }
        return .nearMouse
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

    private func perform(_ action: EditAction) {
        // Fired before the background capture finished: queue it and show the
        // spinner; it runs the moment the selection is ready.
        if capturing {
            lastAction = action
            pendingAction = action
            model.runningTitle = action.progressLabel
            model.phase = .running
            return
        }
        lastAction = action
        currentTask?.cancel()
        autoCloseTask?.cancel()
        autoCloseTask = nil
        currentTask = Task {
            let previousPhase = model.phase
            model.runningTitle = action.progressLabel
            model.phase = .running
            guard let resolved = await resolveInput() else {
                panel.focus()
                if !Task.isCancelled, model.phase == .running { fail("There is no text to edit.") }
                return
            }
            // Input capture may have activated the target app; retake key
            // status so Esc reaches the panel while the provider runs.
            panel.focus()
            let prompt: String
            do {
                try PromptGuard.validate(action: action, text: resolved.text)
                prompt = PromptBuilder.build(action: action, text: resolved.text)
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

    /// Record an applied result in the iteration history and move to the applied
    /// phase (shared by the immediate and confirmed apply paths).
    private func recordApplied(output: String, baseline: String) {
        // Record the iteration: drop any forward history, then append.
        if versions.isEmpty { versions = [baseline] }
        versions = Array(versions.prefix(currentIndex + 1))
        versions.append(output)
        currentIndex = versions.count - 1
        syncIterationState()
        model.instruction = ""
        model.phase = .applied
        panel.focus()
        scheduleAutoCloseIfHybrid()
    }

    // MARK: - Whole-document confirmation

    /// Pause a completed whole-document result in the confirm phase, surfacing
    /// the size change so the user can decide before overwriting everything.
    private func presentConfirmation(output: String, baseline: String) {
        pendingApply = (output, baseline)
        model.pendingOriginalCharCount = baseline.count
        model.pendingResultCharCount = output.count
        model.phase = .confirm
        panel.focus()
    }

    /// Apply the pending whole-document replacement after the user confirmed.
    /// Commit into `.running` before the destructive ⌘A+⌘V so the confirm
    /// affordance can't imply "nothing has happened yet" mid-overwrite; this
    /// mirrors the immediate apply path, which is `.running` while it pastes.
    private func confirmApply() {
        guard model.phase == .confirm, let capture, let pending = pendingApply else { return }
        pendingApply = nil
        model.runningTitle = "Replacing document"
        model.phase = .running
        currentTask?.cancel()
        currentTask = Task {
            await SelectionCapture.apply(text: pending.output, to: capture, entireDocument: true)
            if Task.isCancelled { return }
            recordApplied(output: pending.output, baseline: pending.baseline)
        }
    }

    /// Determine this cycle's input text and apply strategy.
    ///
    /// - Document scope: re-capture via ⌘A+⌘C every cycle, so manual edits the
    ///   user made between cycles (and the navigation position) are respected;
    ///   text that differs from the currently shown version becomes the new
    ///   session baseline (versions = [captured]).
    /// - Selection scope, first cycle: the text captured when the session
    ///   started; the original selection is still live in the target app.
    /// - Selection scope, later cycles: probe with a fresh ⌘C — a new user
    ///   selection becomes the new session baseline. Otherwise the input is
    ///   versions[currentIndex] (what the document shows), replaced via
    ///   undo-then-paste.
    private func resolveInput() async -> (text: String, strategy: ApplyStrategy)? {
        guard let capture else { return nil }
        if model.scope == .document {
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
    private func navigate(to index: Int) {
        guard let capture, model.phase == .applied, !navigating,
              index >= 0, index < versions.count, index != currentIndex else { return }
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
            panel.focus()
        }
    }

    /// Retry after an error. If the field still shows a custom instruction, run
    /// what the user currently sees; otherwise repeat the last action (Improve).
    private func retry() {
        let trimmed = model.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            perform(.custom(trimmed))
        } else if let lastAction {
            perform(lastAction)
        }
    }

    /// Stop the in-flight action but keep the session open.
    private func cancelRun() {
        // While still capturing, the "in-flight" work is only the queued
        // action — dropping it must NOT cancel the capture task, or the session
        // would wedge with `capturing` stuck true. Let the capture finish.
        if capturing {
            pendingAction = nil
            model.phase = .idle
            panel.focus()
            return
        }
        currentTask?.cancel()
        currentTask = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        // Discard any result awaiting confirmation and return to a resting state.
        pendingApply = nil
        model.phase = versions.count > 1 ? .applied : .idle
        panel.focus()
    }

    /// Retake key status for the panel if a session is on screen — used when
    /// the Settings window closes after stealing key from the panel (⌘,).
    func refocusPanel() {
        panel.focus()
    }

    /// Close the session (Esc / Done), keeping the document as shown.
    private func cancel() {
        currentTask?.cancel()
        currentTask = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        pendingApply = nil
        sessionActive = false
        panel.close()
    }

    // MARK: - Post-apply behavior

    /// After an edit lands, hybrid behavior flashes "Improved" then auto-closes
    /// the panel after a short beat. `stayOpen` leaves it up for version nav.
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
            cancel()
        }
    }

    /// Handle a key press routed to the panel. Always cancels the post-apply
    /// auto-close beat so the user can keep iterating. When an edit has been
    /// applied and the field is empty, ← / → navigate between versions (the
    /// keyboard cohort's counterpart to the on-screen chevrons); the event is
    /// consumed so the focused field doesn't just move its caret. Returns
    /// whether the event was consumed.
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
        guard model.phase == .applied,
              model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch event.keyCode {
        case 123: navigate(to: currentIndex - 1); return true // ←
        case 124: navigate(to: currentIndex + 1); return true // →
        default: return false
        }
    }

    private func fail(_ message: String) {
        model.errorText = message
        model.phase = .error
        panel.focus()
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
