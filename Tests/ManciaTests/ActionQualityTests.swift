import Foundation
import Testing
@testable import Mancia

private struct ActionQualityFixture: Decodable {
    let name: String
    let action: String
    let input: String
    let requiredLiterals: [String]
    let forbiddenLiterals: [String]
    let review: String
}

private func actionQualityFixtures() throws -> [ActionQualityFixture] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/action-quality.json")
    return try JSONDecoder().decode(
        [ActionQualityFixture].self,
        from: Data(contentsOf: url)
    )
}

@Test("Visible action prompts state their distinct quality contract")
func visibleActionPromptContracts() {
    let improve = PromptBuilder.build(action: .improve, text: "x", nonce: "N")
    #expect(improve.contains("easy for an AI coding agent to follow"))
    #expect(improve.contains("otherwise improve it as general writing"))

    let sharpen = PromptBuilder.build(action: .sharpen, text: "x", nonce: "N")
    #expect(sharpen.contains("Do not add requirements, assumptions, details, or new intent"))

    let planFirst = PromptBuilder.build(action: .planFirst, text: "x", nonce: "N")
    #expect(planFirst.contains("short plan with explicit goals and verifiers"))
    #expect(planFirst.contains("wait for approval before implementing"))
    #expect(planFirst.contains("Do not answer the request or produce the plan yourself"))

    let tighten = PromptBuilder.build(action: .tighten, text: "x", nonce: "N")
    #expect(tighten.contains("qualification, exception, uncertainty, negation"))
    #expect(tighten.contains("Do not drop or weaken any requirement"))

    let custom = PromptBuilder.build(
        action: .custom("Translate to French and use a table."),
        text: "x",
        nonce: "N"
    )
    #expect(custom.contains("may intentionally translate, reformat, or change tone"))
    #expect(custom.contains("not targeted by the instruction"))
}

@Test("Action quality fixtures cover synthetic fidelity risks")
func actionQualityFixtureCoverage() throws {
    let fixtures = try actionQualityFixtures()
    #expect(fixtures.count == 8)
    #expect(Set(fixtures.map(\.name)).count == fixtures.count)
    #expect(Set(fixtures.map(\.action)).isSuperset(of: [
        "improve", "sharpen", "plan-first", "tighten",
    ]))
    #expect(fixtures.contains { $0.action.hasPrefix("custom:") })

    for fixture in fixtures {
        let action = try #require(EditAction.parse(fixture.action))
        let prompt = PromptBuilder.build(
            action: action,
            text: fixture.input,
            nonce: "FIXTURE"
        )
        #expect(prompt.contains(fixture.input))
        #expect(!fixture.review.isEmpty)
        for literal in fixture.requiredLiterals {
            #expect(fixture.input.contains(literal))
            #expect(prompt.contains(literal))
        }
        for literal in fixture.forbiddenLiterals {
            #expect(!literal.isEmpty)
        }
    }
}

@Test("Preset normalization removes only a complete response fence")
func presetOutputFenceNormalization() throws {
    #expect(try PromptBuilder.normalizeOutput(
        action: .improve,
        source: "source",
        output: "```swift\n let x = 1 \n```\n",
        preserveSourceBoundaryWhitespace: false
    ) == " let x = 1 ")

    let suffixProse = "```\nlet x = 1\n```\nExplanation"
    #expect(try PromptBuilder.normalizeOutput(
        action: .improve,
        source: "source",
        output: suffixProse,
        preserveSourceBoundaryWhitespace: false
    ) == suffixProse)

    let customFence = "```swift\nlet x = 1\n```\n"
    #expect(try PromptBuilder.normalizeOutput(
        action: .custom("Return a fenced Swift block."),
        source: "source",
        output: customFence,
        preserveSourceBoundaryWhitespace: false
    ) == customFence)

    #expect(try PromptBuilder.normalizeOutput(
        action: .improve,
        source: "```swift\nlet x = 0\n```\n",
        output: customFence,
        preserveSourceBoundaryWhitespace: false
    ) == customFence)
}

@Test("Inline preset normalization restores source boundary whitespace")
func presetOutputBoundaryWhitespace() throws {
    let output = try PromptBuilder.normalizeOutput(
        action: .tighten,
        source: "\n  original\t ",
        output: " \nshorter\n ",
        preserveSourceBoundaryWhitespace: true
    )
    #expect(output == "\n  shorter\t ")

    let custom = try PromptBuilder.normalizeOutput(
        action: .custom("Indent by two spaces."),
        source: "\n  original\t ",
        output: "  custom  ",
        preserveSourceBoundaryWhitespace: true
    )
    #expect(custom == "  custom  ")
}

@Test("Provider preserves raw boundaries and rejects whitespace-only output")
func providerRawOutputValidation() throws {
    let raw = "  \n```text\nbody\n```\n "
    #expect(CopilotCLIProvider.postProcess(raw) == raw)
    #expect(try CopilotCLIProvider.validatedOutput(raw) == raw)
    #expect(throws: ProviderError.emptyOutput) {
        try CopilotCLIProvider.validatedOutput(" \n\t ")
    }
    #expect(throws: ProviderError.emptyOutput) {
        try PromptBuilder.normalizeOutput(
            action: .improve,
            source: "source",
            output: "```\n```",
            preserveSourceBoundaryWhitespace: false
        )
    }
}

@Test("Installed provider status does not claim authentication readiness")
func installedProviderStatusLanguage() {
    #expect(ProviderStatus.ready.label == "Installed")
    #expect(ProviderStatus.ready.detail.contains("installed"))
    #expect(ProviderStatus.ready.detail.contains("Sign-in is checked when you run an action"))
}
