import Testing
@testable import Mancia

// MARK: - Prompt templates

@Test("Every action embeds the input text and the output-only clause")
func promptContainsTextAndClause() {
    let sample = "The quick brown fox"
    let actions: [EditAction] = [.rewrite, .summarize, .fixGrammar, .custom("make it formal")]
    for action in actions {
        let prompt = PromptBuilder.build(action: action, text: sample)
        #expect(prompt.contains(sample), "prompt for \(action.title) should contain the input text")
        #expect(prompt.contains(PromptBuilder.outputOnlyClause), "prompt for \(action.title) should contain the output-only clause")
    }
}

@Test("Custom prompt carries the instruction")
func customPromptContainsInstruction() {
    let prompt = PromptBuilder.build(action: .custom("Make it a haiku"), text: "some text")
    #expect(prompt.contains("Make it a haiku"))
}

@Test("Action parsing round-trips CLI identifiers")
func actionParsing() {
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
