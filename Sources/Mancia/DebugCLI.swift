import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// Headless entry points for CI/E2E: exercise the provider pipeline without UI.
enum DebugCLI {
    /// Handle a recognized debug flag. Returns true if it took over the process
    /// (and will `exit`); false to continue to normal app startup.
    @MainActor
    static func handle(_ arguments: [String]) -> Bool {
        if arguments.contains("--provider-check") {
            run { await providerCheck() }
            return true
        }
        if arguments.contains("--list-models") {
            run { await listModels() }
            return true
        }
        if let index = arguments.firstIndex(of: "--complete") {
            let actionArg = index + 1 < arguments.count ? arguments[index + 1] : ""
            run { await complete(actionArg: actionArg) }
            return true
        }
        if arguments.contains("--about-check") {
            aboutCheck()
            return true
        }
        if arguments.contains("--ribbon-click-check") {
            ribbonClickCheck()
            return true
        }
        if let index = arguments.firstIndex(of: "--shoot") {
            let path = index + 1 < arguments.count ? arguments[index + 1] : ""
            run { shoot(path: path) }
            return true
        }
        return false
    }

    /// Run an async body on the main actor, then service the main queue so its
    /// awaits (including MainActor hops) can complete. The body calls `exit`.
    private static func run(_ body: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await body() }
        dispatchMain()
    }

    @MainActor
    private static func providerCheck() async {
        let provider = CopilotCLIProvider(settings: AppSettings())
        let status = await provider.checkAvailability()
        switch status {
        case .ready:
            print("\(provider.displayName): installed; sign-in is checked when an action runs")
            exit(0)
        case .notFound:
            print("\(provider.displayName): not found")
            exit(1)
        case .error(let message):
            print("\(provider.displayName): error — \(message)")
            exit(1)
        }
    }

    /// Print the settings picker's model list exactly as it will be grouped,
    /// and where each entry came from. Useful for confirming that a newly
    /// released model reaches the picker even when `~/.copilot/data.db` is
    /// stale.
    @MainActor
    private static func listModels() async {
        let settings = AppSettings()
        let provider = CopilotCLIProvider(settings: settings)
        let cached = CopilotModelCatalog.modelsForPicker(storedModel: settings.copilotModel)
        let live = await provider.availableModels()
        print("cached: \(cached.count) model(s)   live: \(live.count) model(s)")
        if live.isEmpty {
            print("Live listing unavailable — the picker falls back to the cache.")
        }
        // Same helper Settings binds to, so this can't drift from the picker.
        let merged = CopilotModelCatalog.pickerModels(
            live: live,
            cached: cached,
            storedModel: settings.copilotModel
        )
        let recommended = CopilotModelCatalog.recommendedFastModel(from: merged)
        print("recommended: \(recommended ?? "none")")
        let cachedIDs = Set(cached.map(\.id))
        for tier in CopilotModelCatalog.tiered(merged) {
            print("\n\(tier.title):")
            for model in tier.models {
                let usage = model.usageMultiplier.map { "\($0)x" } ?? "?"
                var notes = ["\(usage)"]
                if !cachedIDs.contains(model.id) { notes.append("live only") }
                if model.id == recommended { notes.append("recommended") }
                print("  \(model.id.padding(toLength: max(model.id.count, 24), withPad: " ", startingAt: 0))  [\(notes.joined(separator: ", "))]")
            }
        }
        exit(0)
    }

    @MainActor
    private static func complete(actionArg: String) async {
        guard let action = EditAction.parse(actionArg) else {
            printErr(
                "Unknown action: \(actionArg). Use improve|sharpen|plan-first|tighten|rewrite|summarize|fix-grammar|custom:<instruction>."
            )
            exit(2)
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = String(data: data, encoding: .utf8) ?? ""
        let settings = AppSettings()
        let provider = CopilotCLIProvider(settings: settings)
        let prompt: String
        do {
            try PromptGuard.validate(action: action, text: input)
            prompt = PromptBuilder.build(action: action, text: input)
        } catch {
            printErr("Error: \(error.localizedDescription)")
            exit(2)
        }
        do {
            let raw = try await provider.complete(prompt)
            let output = try PromptBuilder.normalizeOutput(
                action: action,
                source: input,
                output: raw,
                preserveSourceBoundaryWhitespace: false)
            print(output)
            exit(0)
        } catch {
            printErr("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Verify the About panel: that it reports the bundle's version rather than
    /// a stale literal, and that its red close button actually dismisses it,
    /// on a first open and on a reopen.
    ///
    /// This exists because the About panel is AppKit's, not ours, so a unit
    /// test can't reach its title bar. Run it against the bundle
    /// (`build/Mancia.app/Contents/MacOS/Mancia --about-check`) to check the
    /// real version; under `swift run` there is no Info.plist and the version
    /// reads as `dev`.
    ///
    /// Unlike the headless hooks this drives a real AppKit event loop, so it
    /// runs under `NSApp.run()` rather than `run(_:)`: `dispatchMain()` parks
    /// the main thread with `pthread_exit`, which traps once NSApplication is
    /// alive on it.
    @MainActor
    private static func aboutCheck() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await checkAboutPanel() }
        app.run()
    }

    @MainActor
    private static func checkAboutPanel() async {
        let version = AppVersion.displayString
        let source = AppVersion.short == AppVersion.unbundled
            ? "no Info.plist — running unbundled" : "Info.plist"
        print("version: \(version)  (source: \(source))")

        var failures: [String] = []
        // Twice: the first open builds a fresh panel, the second reuses the one
        // AppKit cached, which is the path a lookalike test would not exercise.
        for attempt in 1...2 {
            AboutPanel.present()
            await settle()

            guard let panel = AboutPanel.currentPanel() else {
                failures.append("open #\(attempt): no About panel appeared")
                continue
            }
            let displayedText = AboutPanel.displayedText(in: panel)
            let displaysVersion = displayedText.contains { $0.contains(version) }
            print(
                "open #\(attempt): displayedVersion=\(displaysVersion ? version : "MISSING")"
            )
            if !displaysVersion {
                failures.append(
                    "open #\(attempt): panel text does not contain bundle version \(version)"
                )
            }
            guard let close = panel.standardWindowButton(.closeButton) else {
                failures.append("open #\(attempt): panel has no close button")
                continue
            }
            let live = close.isEnabled && !close.isHidden
            print(
                "open #\(attempt): visible=\(panel.isVisible) key=\(panel.isKeyWindow) closeButton=\(live ? "live" : "INERT")"
            )
            if !live { failures.append("open #\(attempt): close button is not clickable") }

            close.performClick(nil)
            await settle()
            if panel.isVisible {
                failures.append("open #\(attempt): close button did not dismiss the panel")
            } else {
                print("open #\(attempt): red close button dismissed the panel")
            }
        }

        guard failures.isEmpty else {
            for failure in failures { printErr("Error: \(failure)") }
            exit(1)
        }
        print("About panel OK")
        exit(0)
    }

    /// Give AppKit a beat to order, key, and close windows.
    private static func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Ribbon click check

    /// Verify that the lane's controls answer the mouse. Nothing in
    /// `swift test` can see a SwiftUI button's hit region, so this drives a
    /// real off-screen panel and clicks the way a user does.
    ///
    /// Controls are located by the accessibility identifier `RibbonView`
    /// already publishes for VoiceOver rather than a position baked in ahead
    /// of time, so the check survives the lane's layout moving underneath it.
    /// It walks the phases a real session passes through — idle, Custom, the
    /// whole-document approval gate, the replace-confirmation review, a
    /// retained result, a failure, and a completed apply — asking the model
    /// what ran rather than a real provider, and it never touches the user's
    /// actual pasteboard: the one control that would write to it is
    /// confirmed present rather than clicked.
    @MainActor
    private static func ribbonClickCheck() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await checkRibbonClick() }
        app.run()
    }

    @MainActor
    private static func checkRibbonClick() async {
        let width = RibbonPlacement.standardWidth
        let model = PanelModel()
        model.hasSelection = true
        model.selectionCharCount = 42

        // Isolated callbacks: the model never reaches a real provider, a real
        // document, or the system pasteboard. Every phase this check drives is
        // reached by setting the model directly, the same seam the unit tests
        // use, rather than by running a real edit session.
        var ran: [(action: EditAction, note: String?)] = []
        var cancelRunCount = 0
        var retryCount = 0
        var confirmApplyCount = 0
        var declineCount = 0
        var approveCount = 0
        var copyRetainedCount = 0
        var undoCount = 0
        model.onPerform = { action, note in ran.append((action, note)) }
        model.onCancelRun = { cancelRunCount += 1 }
        model.onRetry = { retryCount += 1 }
        model.onConfirmApply = { confirmApplyCount += 1 }
        model.onDeclinePending = { declineCount += 1 }
        model.onApproveDocumentGeneration = { approveCount += 1 }
        model.onCopyRetainedResult = { copyRetainedCount += 1 }
        model.onScopeChange = { _ in }
        model.onUndoVersion = { undoCount += 1; return true }
        model.onCancel = {}

        let panel = KeyablePanel(
            contentRect: NSRect(x: 200, y: 400, width: width, height: 48),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        let hosting = NSHostingView(
            rootView: RibbonView(model: model, width: width, anchor: .screen, isLive: false))
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        panel.contentView = hosting
        resize(panel: panel, hosting: hosting, model: model)
        panel.makeKeyAndOrderFront(nil)
        await settle()

        guard let axWindow = axWindow(for: panel) else {
            printErr("Error: could not reach the panel through the Accessibility API")
            exit(1)
        }

        var failures: [String] = []
        var log: [String] = []

        func checkBounds(_ state: String) async {
            for id in axIdentifiers(in: axWindow) {
                guard let element = axElement(id: id, in: axWindow),
                      let frame = await windowFrame(of: element, panel: panel)
                else { continue }
                if frame.minX < -2 || frame.maxX > panel.frame.width + 2
                    || frame.minY < -2 || frame.maxY > panel.frame.height + 2 {
                    failures.append("\(state): \(id) extends outside the panel: \(frame)")
                }
            }
        }

        // MARK: idle

        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let idleIDs = axIdentifiers(in: axWindow)
        await checkBounds("idle")
        log.append("idle: \(idleIDs.sorted().joined(separator: ", "))")
        for expected in (1...5).map({ "Action-\($0)" }) where !idleIDs.contains(expected) {
            failures.append("idle: missing control \(expected)")
        }
        if let action5 = axElement(id: "Action-5", in: axWindow), let frame = await windowFrame(of: action5, panel: panel) {
            let margin = NSPoint(x: min(width - 8, frame.maxX + 24), y: frame.midY)
            if isAccent(hosting, at: margin) {
                failures.append("unexpected default accent control in the trailing lane")
            }
        }
        for (identifier, expectedTitle) in [("Action-1", "Improve"), ("Action-2", "Sharpen")] {
            guard let element = axElement(id: identifier, in: axWindow),
                  let frame = await windowFrame(of: element, panel: panel)
            else {
                failures.append("idle: could not locate \(identifier) via accessibility")
                continue
            }
            ran.removeAll()
            click(panel, at: frame.center)
            await settle()
            let titles = ran.map(\.action.title)
            log.append("click (\(identifier)): ran \(titles.isEmpty ? "NOTHING" : titles.joined(separator: ", "))")
            if titles != [expectedTitle] {
                failures.append("click (\(identifier)): expected \(expectedTitle), got \(titles)")
            }
        }

        model.phase = .running
        for stage in ["Reading selection", "Reading document", "Improving", "Applying", "Restoring version"] {
            model.runningTitle = stage
            resize(panel: panel, hosting: hosting, model: model)
            await settle()
            await checkBounds(stage)
        }
        if case .action(let index) = model.primaryFocusCell,
           let active = axElement(id: "Action-\(index + 1)", in: axWindow),
           let frame = await windowFrame(of: active, panel: panel) {
            click(panel, at: frame.center)
            if cancelRunCount != 1 { failures.append("running: active action did not cancel") }
        }
        model.phase = .idle

        // MARK: custom

        model.selectCustomInstruction()
        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let customIDs = axIdentifiers(in: axWindow)
        await checkBounds("custom")
        log.append("custom: \(customIDs.sorted().joined(separator: ", "))")
        for expected in ["CustomInstruction", "Run"] where !customIDs.contains(expected) {
            failures.append("custom: missing control \(expected)")
        }
        if let run = axElement(id: "Run", in: axWindow), let runFrame = await windowFrame(of: run, panel: panel) {
            // Blank Custom is inert: Run is disabled and clicking it dispatches
            // nothing.
            ran.removeAll()
            click(panel, at: runFrame.center)
            await settle()
            if !ran.isEmpty {
                failures.append("custom: Run fired with a blank instruction: \(ran.map(\.action.title))")
            }

            model.instruction = "make it formal"
            resize(panel: panel, hosting: hosting, model: model)
            await settle()
            guard let liveRun = axElement(id: "Run", in: axWindow),
                  let liveRunFrame = await windowFrame(of: liveRun, panel: panel)
            else {
                failures.append("custom: Run disappeared once the field had text")
                return finish(failures: failures, log: log)
            }
            ran.removeAll()
            click(panel, at: liveRunFrame.center)
            await settle()
            log.append("click (Run): ran \(ran.map(\.action.title).joined(separator: ", "))")
            if ran.count != 1 || ran.first?.action != .custom("make it formal") || ran.first?.note != nil {
                failures.append("custom: Run should dispatch the typed instruction, got \(ran)")
            }
        } else {
            failures.append("custom: could not locate Run via accessibility")
        }
        resize(panel: panel, hosting: hosting, model: model, width: RibbonPlacement.customMinimumWidth)
        await settle()
        await checkBounds("narrow custom")

        // MARK: approval (whole-document scope gate)

        model.reset(hasSelection: true, charCount: 42)
        model.phase = .scopeApproval
        model.pendingScopeApprovalActionTitle = "Improve"
        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let approvalIDs = axIdentifiers(in: axWindow)
        log.append("scopeApproval: \(approvalIDs.sorted().joined(separator: ", "))")
        for expected in ["ApproveScope", "DeclineScope"] where !approvalIDs.contains(expected) {
            failures.append("scopeApproval: missing control \(expected)")
        }
        if let action1 = axElement(id: "Action-1", in: axWindow), let frame = await windowFrame(of: action1, panel: panel) {
            ran.removeAll()
            click(panel, at: frame.center)
            await settle()
            if !ran.isEmpty {
                failures.append("scopeApproval: a preset should not dispatch while awaiting approval, got \(ran.map(\.action.title))")
            }
        }
        if let approve = axElement(id: "ApproveScope", in: axWindow),
           let frame = await windowFrame(of: approve, panel: panel)
        {
            approveCount = 0
            click(panel, at: frame.center)
            await settle()
            if approveCount != 1 {
                failures.append("scopeApproval: ApproveScope should call onApproveDocumentGeneration")
            }
        } else {
            failures.append("scopeApproval: could not locate ApproveScope via accessibility")
        }
        if let decline = axElement(id: "DeclineScope", in: axWindow),
           let frame = await windowFrame(of: decline, panel: panel)
        {
            declineCount = 0
            click(panel, at: frame.center)
            await settle()
            if declineCount != 1 {
                failures.append("scopeApproval: DeclineScope should call onDeclinePending")
            }
        } else {
            failures.append("scopeApproval: could not locate DeclineScope via accessibility")
        }
        declineCount = 0
        model.escape()
        if declineCount != 1 {
            failures.append("scopeApproval: Esc should decline the pending approval")
        }

        // MARK: confirm (replace-whole-document review)

        model.reset(hasSelection: false, charCount: 0)
        model.phase = .confirm
        model.pendingOriginalCharCount = 240
        model.pendingResultCharCount = 180
        model.pendingResultPreview = "The replacement text the review region discloses."
        model.pendingOriginalPreview = "The original text before replacement."
        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let confirmIDs = axIdentifiers(in: axWindow)
        log.append("confirm: \(confirmIDs.sorted().joined(separator: ", "))")
        for expected in ["ShowResult", "KeepEditing", "ReplaceDocument"] where !confirmIDs.contains(expected) {
            failures.append("confirm: missing control \(expected)")
        }
        if let showResult = axElement(id: "ShowResult", in: axWindow),
           let frame = await windowFrame(of: showResult, panel: panel)
        {
            let before = model.previewExpanded
            click(panel, at: frame.center)
            await settle()
            if model.previewExpanded == before {
                failures.append("confirm: ShowResult did not toggle the preview disclosure")
            }
            resize(panel: panel, hosting: hosting, model: model)
            await settle()
        }
        if let keepEditing = axElement(id: "KeepEditing", in: axWindow),
           let frame = await windowFrame(of: keepEditing, panel: panel)
        {
            declineCount = 0
            click(panel, at: frame.center)
            await settle()
            if declineCount != 1 {
                failures.append("confirm: KeepEditing should call onDeclinePending")
            }
        }
        if let replaceDocument = axElement(id: "ReplaceDocument", in: axWindow),
           let frame = await windowFrame(of: replaceDocument, panel: panel)
        {
            confirmApplyCount = 0
            click(panel, at: frame.center)
            await settle()
            if confirmApplyCount != 1 {
                failures.append("confirm: ReplaceDocument should call onConfirmApply")
            }
        }

        // MARK: retained (a result Mancia refused to paste)

        model.reset(hasSelection: true, charCount: 42)
        model.phase = .retained
        model.retainedResult = "The result the paste guard held back."
        model.retainedReason = "The frontmost app changed before the edit could land."
        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let retainedIDs = axIdentifiers(in: axWindow)
        log.append("retained: \(retainedIDs.sorted().joined(separator: ", "))")
        for expected in (1...5).map({ "Action-\($0)" }) where !retainedIDs.contains(expected) {
            failures.append("retained: missing control \(expected)")
        }
        for expected in ["RetainedDisclosure", "CopyRetained"] where !retainedIDs.contains(expected) {
            failures.append("retained: missing control \(expected)")
        }
        if let disclosure = axElement(id: "RetainedDisclosure", in: axWindow),
           let frame = await windowFrame(of: disclosure, panel: panel)
        {
            let before = model.retainedResultExpanded
            click(panel, at: frame.center)
            await settle()
            if model.retainedResultExpanded == before {
                failures.append("retained: RetainedDisclosure did not toggle the result disclosure")
            }
            resize(panel: panel, hosting: hosting, model: model)
            await settle()
        }
        // Routed through `onCopyRetainedResult`, a stub closure here, not the
        // pasteboard directly — safe to click, unlike the error strip's Copy.
        if let copyRetained = axElement(id: "CopyRetained", in: axWindow),
           let frame = await windowFrame(of: copyRetained, panel: panel)
        {
            copyRetainedCount = 0
            click(panel, at: frame.center)
            await settle()
            if copyRetainedCount != 1 {
                failures.append("retained: CopyRetained should call onCopyRetainedResult")
            }
        } else {
            failures.append("retained: could not locate CopyRetained via accessibility")
        }

        // MARK: error

        model.reset(hasSelection: true, charCount: 42)
        model.phase = .error
        model.errorText = "Simulated failure for the click check."
        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let errorIDs = axIdentifiers(in: axWindow)
        log.append("error: \(errorIDs.sorted().joined(separator: ", "))")
        for expected in ["ErrorDetails", "CopyError", "Retry"] where !errorIDs.contains(expected) {
            failures.append("error: missing control \(expected)")
        }
        if let errorDetails = axElement(id: "ErrorDetails", in: axWindow),
           let frame = await windowFrame(of: errorDetails, panel: panel)
        {
            let before = model.errorDetailsExpanded
            click(panel, at: frame.center)
            await settle()
            if model.errorDetailsExpanded == before {
                failures.append("error: ErrorDetails did not toggle the failure detail")
            }
            resize(panel: panel, hosting: hosting, model: model)
            await settle()
        }
        if let retry = axElement(id: "Retry", in: axWindow), let frame = await windowFrame(of: retry, panel: panel) {
            retryCount = 0
            click(panel, at: frame.center)
            await settle()
            if retryCount != 1 {
                failures.append("error: Retry should call onRetry")
            }
        }
        // CopyError writes straight to NSPasteboard.general; confirmed present
        // above, deliberately never clicked here.
        log.append("error: CopyError verified present, not invoked (would touch the real pasteboard)")

        // MARK: applied

        model.reset(hasSelection: true, charCount: 42)
        model.phase = .applied
        model.appliedActionName = "Improve"
        model.undoAvailable = true
        resize(panel: panel, hosting: hosting, model: model)
        await settle()
        let appliedIDs = axIdentifiers(in: axWindow)
        log.append("applied: \(appliedIDs.sorted().joined(separator: ", "))")
        for expected in (1...5).map({ "Action-\($0)" }) where !appliedIDs.contains(expected) {
            failures.append("applied: missing control \(expected)")
        }
        if !appliedIDs.contains("UndoApplied") {
            failures.append("applied: missing control UndoApplied")
        }
        if let undo = axElement(id: "UndoApplied", in: axWindow),
           let frame = await windowFrame(of: undo, panel: panel)
        {
            undoCount = 0
            click(panel, at: frame.center)
            await settle()
            if undoCount != 1 {
                failures.append("applied: UndoApplied should call onUndoVersion")
            }
        } else {
            failures.append("applied: could not locate UndoApplied via accessibility")
        }

        // Exercise unmodified digits through the native event routes.
        model.reset(hasSelection: true, charCount: 42)
        panel.onActivateAction = { model.activateAction(at: $0) }
        let digitEvents = zip(["1", "2", "3", "4", "5"], [18, 19, 20, 21, 23]).compactMap {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: $0.0, charactersIgnoringModifiers: $0.0,
                isARepeat: false, keyCode: UInt16($0.1))
        }
        panel.makeFirstResponder(nil)
        ran.removeAll()
        for event in digitEvents { panel.sendEvent(event) }
        if ran.map(\.action.title) != ["Improve", "Sharpen", "Plan first", "Tighten"]
            || !model.isCustomInstructionSelected {
            failures.append("shortcuts: digits did not run presets and open Custom")
        }

        let editor = NSTextView(frame: hosting.bounds)
        panel.contentView = editor
        panel.makeFirstResponder(editor)
        ran.removeAll()
        for event in digitEvents {
            if panel.performKeyEquivalent(with: event) {
                failures.append("shortcuts: a digit was claimed while editing text")
            } else {
                panel.sendEvent(event)
            }
        }
        if editor.string != "12345" || !ran.isEmpty {
            failures.append("shortcuts: digits must type normally in the editor")
        }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        for event in digitEvents {
            if panel.performKeyEquivalent(with: event) {
                failures.append("shortcuts: an unfocused panel claimed a digit")
            }
        }
        log.append("shortcuts: focused digits, ordinary text entry, and unfocused panel")

        finish(failures: failures, log: log)
    }

    /// Report the outcome without touching the user's pasteboard.
    @MainActor
    private static func finish(
        failures: [String], log: [String]
    ) {
        for line in log { print(line) }
        guard failures.isEmpty else {
            for failure in failures { printErr("Error: \(failure)") }
            exit(1)
        }
        print("Ribbon action controls OK")
        exit(0)
    }

    /// Lay the lane out for its current phase and grow the panel and hosting
    /// view to fit — the same two-pass measurement `RibbonWindow` uses, so a
    /// phase that discloses more (Custom's field, the confirm review, an
    /// expanded failure detail) has real geometry to click into rather than
    /// being clipped by the check's own fixed frame.
    ///
    /// Width is resolved from the model, not a fixed constant: Custom's
    /// disclosed field needs `RibbonPlacement.expandedWidth`, the same swap
    /// `RibbonWindow.currentContext()` makes, or its Run control (and
    /// anything else in that wider row) reports an accessibility frame past
    /// the edge of a lane still sized for the standard width. The live
    /// hosting view's `rootView` is reassigned to match — a `RibbonView`'s
    /// `width` is a plain `let`, so nothing about the width it renders at
    /// changes just because the panel's own frame does.
    @MainActor
    private static func resize(
        panel: NSPanel, hosting: NSHostingView<RibbonView>, model: PanelModel,
        width requestedWidth: CGFloat? = nil
    ) {
        let width = requestedWidth ?? (model.prefersExpandedRibbon
            ? RibbonPlacement.expandedWidth : RibbonPlacement.standardWidth)
        let measurement = NSHostingView(
            rootView: RibbonView(model: model, width: width, anchor: .screen, isLive: false))
        measurement.safeAreaRegions = []
        let height = max(48, measurement.fittingSize.height)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        hosting.rootView = RibbonView(model: model, width: width, anchor: .screen, isLive: false)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.layoutSubtreeIfNeeded()
    }

    /// Every accessibility identifier reachable from `root`'s descendants —
    /// the same tree VoiceOver walks.
    @MainActor
    private static func axIdentifiers(in root: AXUIElement) -> Set<String> {
        var found: Set<String> = []
        collectAX(root) { element in
            if let identifier = axAttribute(element, kAXIdentifierAttribute) as? String,
               !identifier.isEmpty
            {
                found.insert(identifier)
            }
        }
        return found
    }

    /// The first descendant of `root` carrying accessibility identifier `id`.
    @MainActor
    private static func axElement(id: String, in root: AXUIElement) -> AXUIElement? {
        var match: AXUIElement?
        collectAX(root) { element in
            guard match == nil,
                  let identifier = axAttribute(element, kAXIdentifierAttribute) as? String,
                  identifier == id
            else { return }
            match = element
        }
        return match
    }

    /// Depth-first walk of the real accessibility tree rooted at `root` — the
    /// window `panel` shows in this same process, reached through the system
    /// Accessibility API rather than any private SwiftUI introspection. This
    /// is how `.accessibilityIdentifier(_:)` becomes something a click check
    /// can find: SwiftUI only builds its accessibility representation for the
    /// real API, not for direct calls against `NSHostingView`.
    ///
    /// Querying it needs the calling process to already be an accessibility
    /// client, which Mancia's own pasteboard/keystroke work already requires
    /// — this reuses that trust rather than asking for anything new.
    @MainActor
    private static func collectAX(_ root: AXUIElement, visit: (AXUIElement) -> Void) {
        visit(root)
        for child in axAttribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collectAX(child, visit: visit)
        }
    }

    @MainActor
    private static func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// The `AXUIElement` for `panel`'s own window, found among this process's
    /// windows rather than assumed to be the only one.
    @MainActor
    private static func axWindow(for panel: NSPanel) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let windows = axAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
            return nil
        }
        return windows.first { window in
            axFrame(window).map { flippedToAppKit($0).intersects(panel.frame.insetBy(dx: -1, dy: -1)) }
                ?? false
        } ?? windows.first
    }

    /// An element's frame in Accessibility's coordinate space: origin at the
    /// top-left of the primary display, y increasing downward.
    @MainActor
    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axAttribute(element, kAXPositionAttribute),
              let sizeValue = axAttribute(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Flip an Accessibility frame into AppKit's screen space: origin at the
    /// bottom-left of the primary display, y increasing upward — the space
    /// `NSWindow.frame` and `NSEvent.mouseEvent` both already use.
    @MainActor
    private static func flippedToAppKit(_ axFrame: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? axFrame.maxY
        return NSRect(
            x: axFrame.origin.x, y: primaryHeight - axFrame.maxY,
            width: axFrame.width, height: axFrame.height)
    }

    /// Where a real click on `element` should land, in the base coordinates
    /// `click(_:at:)` expects (i.e. relative to `panel`'s own frame).
    ///
    /// Polls rather than reading once: the Accessibility server republishes a
    /// control's own frame a beat after the window's, so a read taken right
    /// after a resize can still describe where the control was before it —
    /// worse under the load a concurrent build puts on the same machine.
    /// Waiting for two identical, in-bounds reads in a row is cheap insurance
    /// against clicking where a control used to be.
    @MainActor
    private static func windowFrame(of element: AXUIElement, panel: NSPanel) async -> NSRect? {
        var previous: NSRect?
        for _ in 0..<20 {
            guard let axFrame = axFrame(element) else { return previous }
            let screenFrame = flippedToAppKit(axFrame)
            let origin = panel.frame.origin
            let frame = NSRect(
                x: screenFrame.origin.x - origin.x, y: screenFrame.origin.y - origin.y,
                width: screenFrame.width, height: screenFrame.height)
            // A control's own frame can legitimately extend a few points past
            // the lane's edge (shadow, focus-ring inset); it is the center a
            // click aims at, so that is what has to land inside the panel.
            let inBounds = frame.midY >= 0 && frame.midY <= panel.frame.height
            if inBounds, let previous, previous == frame {
                return frame
            }
            previous = inBounds ? frame : previous
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return previous
    }

    /// Whether the lane draws its accent at `point` — vermilion is far enough
    /// off the lane's browns to test by channel rather than by exact value,
    /// which keeps this honest whatever colour space the display renders in.
    @MainActor
    private static func isAccent(_ view: NSView, at point: NSPoint) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Bitmap rows count from the top; the view's coordinates from the foot.
        guard let color = rep.colorAt(x: Int(point.x), y: Int(view.bounds.height - point.y)),
              let rgb = color.usingColorSpace(.sRGB)
        else { return false }
        return rgb.redComponent - rgb.greenComponent > 0.3
            && rgb.redComponent - rgb.blueComponent > 0.3
    }

    /// A press and a release delivered straight to the panel. Synthesized
    /// rather than posted through the event tap, so this needs no Accessibility
    /// permission and cannot disturb whatever else is on screen.
    @MainActor
    private static func click(_ panel: NSPanel, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            panel.sendEvent(event)
        }
    }

    /// Redraw the README's hero image. Documentation upkeep rather than an app
    /// feature, but it renders the shipping ribbon view, so it lives with the
    /// code that would otherwise silently make the picture a lie.
    @MainActor
    private static func shoot(path: String) {
        guard !path.isEmpty, !path.hasPrefix("-") else {
            printErr("Usage: --shoot <output.png>")
            exit(2)
        }
        // The renderer needs an app object for its off-screen window, but this
        // process must never take focus or appear in the Dock.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The document in the shot is a light-appearance surface regardless of
        // how the machine running this is set.
        app.appearance = NSAppearance(named: .aqua)
        do {
            try DocsShot.render(to: path)
            print("Wrote \(path)")
            exit(0)
        } catch {
            printErr("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// File-scoped: a click target is always this rect's midpoint, and spelling
/// that out at every call site in the ribbon click check would bury the
/// control names the checks are actually about.
private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
