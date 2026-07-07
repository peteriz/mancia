import AppKit

/// Orchestrates a cyclical edit session: capture selection → show panel →
/// run provider → apply inline → toggle/compare or run further actions, until
/// the user closes the session. Owns the panel and the in-flight task.
@MainActor
final class EditCoordinator {
    private let registry: ProviderRegistry
    private let settings: AppSettings
    private let model = PanelModel()
    private let panel: EditPanel

    private var capture: SelectionCaptureResult?
    private var currentTask: Task<Void, Never>?
    private var lastAction: EditAction?
    /// The text the session started from (first action's input; reset when the
    /// user makes a fresh selection mid-session). Compared by the toggle.
    private var sessionOriginal: String?
    /// The most recently applied provider output.
    private var latestOutput: String?

    init(registry: ProviderRegistry, settings: AppSettings) {
        self.registry = registry
        self.settings = settings
        self.panel = EditPanel(model: model)
        wire()
    }

    private func wire() {
        model.onPerform = { [weak self] in self?.perform($0) }
        model.onSelectVersion = { [weak self] in self?.selectVersion($0) }
        model.onRetry = { [weak self] in self?.retry() }
        model.onCancelRun = { [weak self] in self?.cancelRun() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onClose = { [weak self] in self?.cancel() }
    }

    /// Entry point from hotkey or menu. Starts a fresh session.
    func start() {
        guard ensureAccessibility() else { return }
        currentTask?.cancel()
        Task {
            let result = await SelectionCapture.captureSelection()
            self.capture = result
            self.sessionOriginal = nil
            self.latestOutput = nil
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
        /// ⌘V over the live selection (first cycle, fresh user selection, or
        /// the undo-restored selection when the toggle shows Original).
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
                if !Task.isCancelled, model.phase == .running { fail("There is no text to edit.") }
                return
            }
            guard let provider = registry.current else {
                fail("No AI provider is configured.")
                return
            }
            let prompt = PromptBuilder.build(action: action, text: resolved.text)
            do {
                let output = try await provider.complete(prompt)
                if Task.isCancelled { return }
                guard let capture else { return }
                // Apply immediately: hide the panel first so the synthetic
                // keystrokes reach the target app, then reveal the panel with
                // the applied strip (Original | Rewritten toggle).
                panel.hide()
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
                if sessionOriginal == nil { sessionOriginal = resolved.text }
                latestOutput = output
                model.appliedVersion = .rewritten
                model.instruction = ""
                model.phase = .applied
                panel.reveal()
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
    ///   user made between cycles (and the toggle position) are respected.
    /// - Selection scope, first cycle: the text captured when the session
    ///   started; the original selection is still live in the target app.
    /// - Selection scope, later cycles: probe with a fresh ⌘C — a new user
    ///   selection wins and resets the session original. Otherwise the input
    ///   is the version currently shown per the toggle: the latest output
    ///   (replaced via undo-then-paste) or the session original (already
    ///   restored and re-selected in the document by the toggle's ⌘Z).
    private func resolveInput() async -> (text: String, strategy: ApplyStrategy)? {
        guard let capture else { return nil }
        if model.scope == .document {
            // Hide the panel so the synthetic ⌘A/⌘C reaches the target app,
            // then bring it back so the user sees the running spinner.
            panel.hide()
            let text = await SelectionCapture.captureEntireDocument(from: capture)
            panel.reveal()
            guard let text, !text.isEmpty else { return nil }
            return (text, .entireDocument)
        }
        if latestOutput == nil {
            guard let text = capture.text, !text.isEmpty else { return nil }
            return (text, .liveSelection)
        }
        // Later cycle: check for a fresh user selection first.
        panel.hide()
        let fresh = await SelectionCapture.captureFreshSelection(from: capture)
        panel.reveal()
        if let fresh, !fresh.isEmpty {
            let isRestoredCurrent = fresh == currentVersionText
            if !isRestoredCurrent {
                // A genuinely new selection starts a new sub-edit.
                sessionOriginal = fresh
            }
            return (fresh, .liveSelection)
        }
        guard let text = currentVersionText, !text.isEmpty else { return nil }
        return (text, model.appliedVersion == .rewritten ? .undoThenPaste : .liveSelection)
    }

    /// The text currently shown in the document per the toggle.
    private var currentVersionText: String? {
        model.appliedVersion == .rewritten ? latestOutput : sessionOriginal
    }

    /// Show the session original or the latest output in the document.
    ///
    /// - Selection scope: ride the target app's native undo stack — ⌘Z shows
    ///   the original (undo of a paste also re-selects the replaced text),
    ///   ⇧⌘Z (redo) brings the latest back. The undo-then-paste apply strategy
    ///   keeps this a single step even after repeated cycles.
    /// - Document scope: re-apply the tracked text via ⌘A+⌘V, which stays
    ///   correct even when the user manually edited between cycles (a single
    ///   ⌘Z would only undo their typing).
    private func selectVersion(_ version: PanelModel.Version) {
        guard let capture, model.phase == .applied, version != model.appliedVersion else { return }
        let text = version == .original ? sessionOriginal : latestOutput
        guard let text else { return }
        model.appliedVersion = version
        currentTask?.cancel()
        currentTask = Task {
            // Order the panel out first so the synthetic keystrokes are
            // delivered to the target app rather than being consumed here,
            // then bring it back so the user can keep toggling.
            panel.hide()
            if model.scope == .document {
                await SelectionCapture.apply(text: text, to: capture, entireDocument: true)
            } else {
                switch version {
                case .original: await SelectionCapture.undo(in: capture)
                case .rewritten: await SelectionCapture.redo(in: capture)
                }
            }
            panel.reveal()
        }
    }

    private func retry() {
        if let lastAction { perform(lastAction) }
    }

    /// Stop the in-flight action but keep the session open.
    private func cancelRun() {
        currentTask?.cancel()
        currentTask = nil
        model.phase = latestOutput == nil ? .idle : .applied
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
