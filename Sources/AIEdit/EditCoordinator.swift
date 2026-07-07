import AppKit

/// Orchestrates the full flow: capture selection → show panel → run provider →
/// apply the result. Owns the panel and the in-flight task.
@MainActor
final class EditCoordinator {
    private let registry: ProviderRegistry
    private let settings: AppSettings
    private let model = PanelModel()
    private let panel: EditPanel

    private var capture: SelectionCaptureResult?
    private var currentTask: Task<Void, Never>?
    private var lastAction: EditAction?

    init(registry: ProviderRegistry, settings: AppSettings) {
        self.registry = registry
        self.settings = settings
        self.panel = EditPanel(model: model)
        wire()
    }

    private func wire() {
        model.onPerform = { [weak self] in self?.perform($0) }
        model.onApply = { [weak self] in self?.apply() }
        model.onCopy = { [weak self] in self?.copyResult() }
        model.onRetry = { [weak self] in self?.retry() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onClose = { [weak self] in self?.cancel() }
    }

    /// Entry point from hotkey or menu.
    func start() {
        guard ensureAccessibility() else { return }
        currentTask?.cancel()
        Task {
            let result = await SelectionCapture.captureSelection()
            self.capture = result
            model.reset(hasSelection: result.text != nil, charCount: result.text?.count ?? 0)
            panel.show()
        }
    }

    // MARK: - Actions

    private func perform(_ action: EditAction) {
        lastAction = action
        currentTask?.cancel()
        currentTask = Task {
            model.phase = .running
            guard let text = await resolveInputText(), !text.isEmpty else {
                fail("There is no text to edit.")
                return
            }
            guard let provider = registry.current else {
                fail("No AI provider is configured.")
                return
            }
            let prompt = PromptBuilder.build(action: action, text: text, targetLanguage: settings.targetLanguage)
            do {
                let output = try await provider.complete(prompt)
                if Task.isCancelled { return }
                model.resultText = output
                model.phase = .result
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func resolveInputText() async -> String? {
        guard let capture else { return nil }
        if model.scope == .document {
            // Hide the panel so the synthetic ⌘A/⌘C reaches the target app,
            // then bring it back so the user sees the running spinner.
            panel.hide()
            let text = await SelectionCapture.captureEntireDocument(from: capture)
            panel.reveal()
            return text
        }
        return capture.text
    }

    private func apply() {
        guard let capture else { return }
        let text = model.resultText
        let entire = model.scope == .document
        currentTask?.cancel()
        currentTask = Task {
            // Order the panel out first so the synthetic ⌘V (and ⌘A) is
            // delivered to the target app rather than being consumed here.
            panel.hide()
            await SelectionCapture.apply(text: text, to: capture, entireDocument: entire)
            panel.close()
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.resultText, forType: .string)
        panel.close()
    }

    private func retry() {
        if let lastAction { perform(lastAction) }
    }

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
