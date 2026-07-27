import Foundation

/// Headless entry points for CI/E2E: exercise the provider pipeline without UI.
enum DebugCLI {
    /// Handle a recognized debug flag. Returns true if it took over the process
    /// (and will `exit`); false to continue to normal app startup.
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
            printErr("Unknown action: \(actionArg). Use improve|rewrite|summarize|fix-grammar|custom:<instruction>.")
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

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
