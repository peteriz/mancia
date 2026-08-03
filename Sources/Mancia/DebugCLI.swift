import AppKit
import Foundation

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
            print("\(provider.displayName): ready")
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
            let output = try await provider.complete(prompt)
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
