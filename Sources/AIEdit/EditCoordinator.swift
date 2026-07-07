import AppKit

/// Orchestrates a cyclical edit session: capture selection → show panel →
/// run provider → apply inline → navigate between iterations or run further
/// actions, until the user closes the session. Owns the panel and the
/// in-flight task. The panel stays visible throughout — synthetic keystrokes
/// are posted to the target app's pid, so they can't be swallowed by it.
@MainActor
final class EditCoordinator {
    private let provider: LLMProvider
    private let model = PanelModel()
    private let panel: EditPanel

    private var capture: SelectionCaptureResult?
    private var currentTask: Task<Void, Never>?
    private var lastAction: EditAction?
    /// Iteration history: versions[0] is the session original (reset when the
    /// user makes a fresh selection or manual edit mid-session), followed by
    /// one entry per applied result.
    private var versions: [String] = []
    /// Which version the document currently shows.
    private var currentIndex = 0
    /// Guards against overlapping navigation keystroke sequences.
    private var navigating = false

    init(provider: LLMProvider) {
        self.provider = provider
        self.panel = EditPanel(model: model)
        wire()
    }

    private func wire() {
        model.onPerform = { [weak self] in self?.perform($0) }
        model.onNavigate = { [weak self] in self?.navigate(to: $0) }
        model.onRetry = { [weak self] in self?.retry() }
        model.onCancelRun = { [weak self] in self?.cancelRun() }
        model.onCancel = { [weak self] in self?.cancel() }
    }

    /// Entry point from hotkey or menu. Starts a fresh session.
    func start() {
        guard ensureAccessibility() else { return }
        currentTask?.cancel()
        Task {
            let result = await SelectionCapture.captureSelection()
            self.capture = result
            self.versions = []
            self.currentIndex = 0
            self.navigating = false
            let hasSelection = result.text != nil
            model.reset(hasSelection: hasSelection, charCount: result.text?.count ?? 0)
            panel.show(placement: placement(hasSelection: hasSelection))
        }
    }

    /// Near the caret/selection when there is one (mouse as fallback);
    /// centered on the main screen for entire-document scope.
    private func placement(hasSelection: Bool) -> EditPanel.Placement {
        guard hasSelection else { return .centered }
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
        lastAction = action
        currentTask?.cancel()
        currentTask = Task {
            let previousPhase = model.phase
            model.runningTitle = action.title
            model.phase = .running
            guard let resolved = await resolveInput() else {
                panel.focus()
                if !Task.isCancelled, model.phase == .running { fail("There is no text to edit.") }
                return
            }
            // Input capture may have activated the target app; retake key
            // status so Esc reaches the panel while the provider runs.
            panel.focus()
            let prompt = PromptBuilder.build(action: action, text: resolved.text)
            do {
                let output = try await provider.complete(prompt)
                if Task.isCancelled { return }
                guard let capture else { return }
                // Apply immediately. Keystrokes are posted to the target
                // app's pid, so the panel stays visible throughout.
                switch resolved.strategy {
                case .entireDocument:
                    await SelectionCapture.apply(text: output, to: capture, entireDocument: true)
                case .liveSelection:
                    await SelectionCapture.apply(text: output, to: capture, entireDocument: false)
                case .undoThenPaste:
                    await SelectionCapture.undo(in: capture)
                    await SelectionCapture.apply(text: output, to: capture, entireDocument: false)
                }
                if Task.isCancelled { return }
                // Record the iteration: drop any forward history, then append.
                if versions.isEmpty { versions = [resolved.text] }
                versions = Array(versions.prefix(currentIndex + 1))
                versions.append(output)
                currentIndex = versions.count - 1
                syncIterationState()
                model.instruction = ""
                model.phase = .applied
                panel.focus()
            } catch is CancellationError {
                if model.phase == .running { model.phase = previousPhase }
                return
            } catch {
                if Task.isCancelled { return }
                fail(error.localizedDescription)
            }
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

    private func retry() {
        if let lastAction { perform(lastAction) }
    }

    /// Stop the in-flight action but keep the session open.
    private func cancelRun() {
        currentTask?.cancel()
        currentTask = nil
        model.phase = versions.count > 1 ? .applied : .idle
        panel.focus()
    }

    /// Close the session (Esc / Done), keeping the document as shown.
    private func cancel() {
        currentTask?.cancel()
        currentTask = nil
        panel.close()
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
        alert.informativeText = "AI-Edit needs Accessibility access to read your selection and paste results.\n\nEnable it in System Settings ▸ Privacy & Security ▸ Accessibility, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
        return false
    }
}
