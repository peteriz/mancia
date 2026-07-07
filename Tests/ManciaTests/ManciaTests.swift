import Testing
import Foundation
@testable import Mancia

// MARK: - Prompt templates

@Test("Every action embeds the input text and the output-only clause")
func promptContainsTextAndClause() {
    let sample = "The quick brown fox"
    let actions: [EditAction] = [.improve, .rewrite, .summarize, .fixGrammar, .custom("make it formal")]
    for action in actions {
        let prompt = PromptBuilder.build(action: action, text: sample)
        #expect(prompt.contains(sample), "prompt for \(action.title) should contain the input text")
        #expect(prompt.contains(PromptBuilder.outputOnlyClause), "prompt for \(action.title) should contain the output-only clause")
        #expect(prompt.contains("Task:\n"), "prompt for \(action.title) should include a task section")
        #expect(prompt.contains("Requirements:\n"), "prompt for \(action.title) should include a requirements section")
        #expect(prompt.contains("Input text:\n<<<\n\(sample)\n>>>"), "prompt for \(action.title) should delimit the input text")
    }
}

@Test("Preset prompt templates carry action-specific guidance")
func presetPromptTemplatesAreSpecific() {
    let rewrite = PromptBuilder.build(action: .rewrite, text: "some text")
    #expect(rewrite.contains("Rewrite the text for clarity, flow, and natural phrasing."))
    #expect(rewrite.contains("Do not add information, examples, claims, or opinions."))

    let summarize = PromptBuilder.build(action: .summarize, text: "some text")
    #expect(summarize.contains("Summarize the text."))
    #expect(summarize.contains("Use clear, concise language in the same language as the source text."))

    let proofread = PromptBuilder.build(action: .fixGrammar, text: "some text")
    #expect(proofread.contains("Proofread the text."))
    #expect(proofread.contains("Change only what is needed for correctness."))
}

@Test("Improve prompt preserves meaning and improves wording")
func improvePromptShape() {
    let prompt = PromptBuilder.build(action: .improve, text: "helo wrld")
    #expect(prompt.contains("helo wrld"))
    #expect(prompt.lowercased().contains("meaning"))
    #expect(prompt.lowercased().contains("improve"))
}

@Test("Custom prompt carries the instruction")
func customPromptContainsInstruction() {
    let prompt = PromptBuilder.build(action: .custom("Make it a haiku"), text: "some text")
    #expect(prompt.contains("Apply the user instruction to the input text."))
    #expect(prompt.contains("User instruction:\n<<<\nMake it a haiku\n>>>"))
    #expect(prompt.contains("Follow the user instruction exactly, without adding unrelated changes."))
}

@Test("Action parsing round-trips CLI identifiers")
func actionParsing() {
    #expect(EditAction.parse("improve") == .improve)
    #expect(EditAction.parse("rewrite") == .rewrite)
    #expect(EditAction.parse("summarize") == .summarize)
    #expect(EditAction.parse("fix-grammar") == .fixGrammar)
    #expect(EditAction.parse("custom:be terse") == .custom("be terse"))
    #expect(EditAction.parse("translate") == nil)
    #expect(EditAction.parse("reply") == nil)
    #expect(EditAction.parse("nonsense") == nil)
}

// MARK: - Copilot argv construction

@Test("Argv includes the empty --available-tools as a single element")
func argvHasEmptyAvailableTools() {
    let args = CopilotCLIProvider.arguments(executable: "/opt/homebrew/bin/copilot", prompt: "hi", model: "")
    #expect(args.contains("--available-tools="))
    #expect(!args.contains("--model"))
    #expect(args.contains("-s"))
    #expect(args.contains("--no-color"))
    #expect(args.contains("--no-custom-instructions"))
    // prompt is passed as its own element right after -p
    let promptIndex = args.firstIndex(of: "-p")
    #expect(promptIndex != nil)
    #expect(args[promptIndex! + 1] == "hi")
}

@Test("Argv appends --model when a model is set")
func argvIncludesModel() {
    let args = CopilotCLIProvider.arguments(executable: "/opt/homebrew/bin/copilot", prompt: "hi", model: "gpt-5")
    let modelIndex = args.firstIndex(of: "--model")
    #expect(modelIndex != nil)
    #expect(args[modelIndex! + 1] == "gpt-5")
}

@Test("Argv appends --reasoning-effort when an effort level is set")
func argvIncludesReasoningEffort() {
    let args = CopilotCLIProvider.arguments(
        executable: "/opt/homebrew/bin/copilot", prompt: "hi", model: "claude-sonnet-4.6", reasoningEffort: "high"
    )
    let effortIndex = args.firstIndex(of: "--reasoning-effort")
    #expect(effortIndex != nil)
    #expect(args[effortIndex! + 1] == "high")
}

@Test("Argv omits --reasoning-effort when unset (Default)")
func argvOmitsReasoningEffort() {
    let args = CopilotCLIProvider.arguments(executable: "/opt/homebrew/bin/copilot", prompt: "hi", model: "")
    #expect(!args.contains("--reasoning-effort"))
    let blank = CopilotCLIProvider.arguments(executable: "/opt/homebrew/bin/copilot", prompt: "hi", model: "", reasoningEffort: "  ")
    #expect(!blank.contains("--reasoning-effort"))
}

// MARK: - Copilot model catalog

@Test("Model catalog decodes id, name, and reasoning efforts from cached JSON")
func modelCatalogDecodes() {
    let json = """
    [{"id":"auto","name":"Auto","capabilities":{}},
     {"id":"claude-sonnet-4.6","name":"Claude Sonnet 4.6","defaultReasoningEffort":"medium",
      "supportedReasoningEfforts":["low","medium","high","max"],"capabilities":{"supports":{"reasoningEffort":true}}}]
    """
    let models = CopilotModelCatalog.decode(json)
    #expect(models?.count == 2)
    #expect(models?[0] == CopilotModel(id: "auto", name: "Auto", supportedReasoningEfforts: nil))
    #expect(models?[1].id == "claude-sonnet-4.6")
    #expect(models?[1].supportedReasoningEfforts == ["low", "medium", "high", "max"])
}

@Test("Model catalog falls back to auto plus the stored model when unreadable")
func modelCatalogFallback() {
    let models = CopilotModelCatalog.modelsForPicker(storedModel: "my-model", dbPath: "/nonexistent/data.db")
    #expect(models.map(\.id) == ["auto", "my-model"])
    let noStored = CopilotModelCatalog.modelsForPicker(storedModel: "", dbPath: "/nonexistent/data.db")
    #expect(noStored.map(\.id) == ["auto"])
}

@Test("Model catalog drops duplicate ids and entries missing id/name")
func modelCatalogDedupesAndFilters() {
    let json = """
    [{"id":"auto","name":"Auto"},
     {"id":"auto","name":"Auto Duplicate"},
     {"id":"","name":"No Id"},
     {"id":"gpt-5","name":""},
     {"id":"claude","name":"Claude"}]
    """
    let models = CopilotModelCatalog.decode(json)
    #expect(models?.map(\.id) == ["auto", "claude"])
}

@Test("Model catalog returns nil for entirely malformed JSON")
func modelCatalogRejectsGarbage() {
    #expect(CopilotModelCatalog.decode("not json at all") == nil)
    #expect(CopilotModelCatalog.decode("[]") == nil)
}

@Test("env fallback prepends the copilot argument")
func argvEnvFallback() {
    let args = CopilotCLIProvider.arguments(executable: "/usr/bin/env", prompt: "hi", model: "")
    #expect(args.first == "copilot")
}

// MARK: - Output post-processing

@Test("Post-processing trims surrounding whitespace")
func postProcessTrims() {
    #expect(CopilotCLIProvider.postProcess("  \n hello world \n ") == "hello world")
}

@Test("Post-processing strips a wrapping code fence, keeping inner content")
func postProcessStripsFence() {
    let fenced = "```\nline one\nline two\n```"
    #expect(CopilotCLIProvider.postProcess(fenced) == "line one\nline two")
    let langFenced = "```swift\nlet x = 1\n```"
    #expect(CopilotCLIProvider.postProcess(langFenced) == "let x = 1")
}

@Test("Post-processing leaves fence-free text untouched")
func postProcessLeavesPlainText() {
    #expect(CopilotCLIProvider.postProcess("just text") == "just text")
    // inner backticks that aren't a wrapping fence stay put
    #expect(CopilotCLIProvider.postProcess("use `let` here") == "use `let` here")
}

// MARK: - Binary discovery order

@Test("Explicit override wins when it exists")
func discoveryOverride() {
    let path = CopilotCLIProvider.resolveExecutable(override: "/custom/copilot") { $0 == "/custom/copilot" }
    #expect(path == "/custom/copilot")
}

@Test("Discovery prefers homebrew over local paths")
func discoveryOrder() {
    let existing: Set<String> = ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"]
    let path = CopilotCLIProvider.resolveExecutable(override: nil) { existing.contains($0) }
    #expect(path == "/opt/homebrew/bin/copilot")
}

@Test("Discovery falls back to env when nothing is found")
func discoveryEnvFallback() {
    let path = CopilotCLIProvider.resolveExecutable(override: nil) { _ in false }
    #expect(path == "/usr/bin/env")
}

@Test("A non-existent override is ignored in favor of search paths")
func discoveryIgnoresMissingOverride() {
    let path = CopilotCLIProvider.resolveExecutable(override: "/nope/copilot") { $0 == "/usr/local/bin/copilot" }
    #expect(path == "/usr/local/bin/copilot")
}

// MARK: - Missing-binary detection

@Test("env command-not-found (exit 127) is detected as a missing binary")
func missingBinaryDetectedFromEnv() {
    #expect(CopilotCLIProvider.looksMissingBinary(
        exitCode: 127, text: "env: copilot: No such file or directory"))
    #expect(CopilotCLIProvider.looksMissingBinary(
        exitCode: 127, text: "copilot: command not found"))
}

@Test("A real copilot error (non-127 exit) is not treated as missing")
func realErrorNotMissingBinary() {
    // Copilot ran but failed for another reason: keep it as a real error.
    #expect(!CopilotCLIProvider.looksMissingBinary(
        exitCode: 1, text: "some copilot failure"))
    // Exit 127 without a not-found message stays a normal error.
    #expect(!CopilotCLIProvider.looksMissingBinary(
        exitCode: 127, text: "unexpected internal state"))
    #expect(!CopilotCLIProvider.looksMissingBinary(
        exitCode: 0, text: "all good"))
}

// MARK: - Binary discovery locations

@Test("Search paths cover Homebrew, local, and npm-global prefixes")
func searchPathsCoverCommonPrefixes() {
    let paths = CopilotCLIProvider.searchPaths()
    #expect(paths.contains("/opt/homebrew/bin/copilot"))
    #expect(paths.contains("/usr/local/bin/copilot"))
    #expect(paths.contains(NSHomeDirectory() + "/.local/bin/copilot"))
    #expect(paths.contains(NSHomeDirectory() + "/.npm-global/bin/copilot"))
    // Every entry targets the copilot binary.
    #expect(paths.allSatisfy { $0.hasSuffix("/copilot") })
}

@Test("isRunnableFile rejects directories and accepts executables")
func isRunnableFileChecksType() {
    // A directory that exists but is not a runnable file.
    #expect(!CopilotCLIProvider.isRunnableFile(NSHomeDirectory()))
    // A well-known executable regular file.
    #expect(CopilotCLIProvider.isRunnableFile("/bin/ls"))
    #expect(!CopilotCLIProvider.isRunnableFile("/nonexistent/copilot"))
}

@Test("augmentedPath prepends install dirs and dedupes against the base PATH")
func augmentedPathPrependsAndDedupes() {
    let augmented = CopilotCLIProvider.augmentedPath(base: "/usr/bin:/opt/homebrew/bin")
    let parts = augmented.split(separator: ":").map(String.init)
    // Install dirs are present.
    #expect(parts.contains("/opt/homebrew/bin"))
    #expect(parts.contains("/usr/local/bin"))
    // No duplicates even though the base repeats an install dir.
    #expect(parts.count == Set(parts).count)
    // Works with no base PATH.
    #expect(!CopilotCLIProvider.augmentedPath(base: nil).isEmpty)
}
