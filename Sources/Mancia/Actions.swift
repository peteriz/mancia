import Foundation

/// A text-editing action the user can invoke from the panel.
enum EditAction: Equatable, Sendable {
    case rewrite
    case summarize
    case fixGrammar
    case custom(String)

    /// Short user-facing label for buttons/menus.
    var title: String {
        switch self {
        case .rewrite: return "Rewrite"
        case .summarize: return "Summarize"
        case .fixGrammar: return "Proofread"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol name for the button.
    var symbol: String {
        switch self {
        case .rewrite: return "pencil.and.outline"
        case .summarize: return "text.line.first.and.arrowtriangle.forward"
        case .fixGrammar: return "text.badge.checkmark"
        case .custom: return "sparkles"
        }
    }

    /// Parse the CLI/debug identifier for an action ("fix-grammar", "custom:...").
    static func parse(_ raw: String) -> EditAction? {
        if raw.hasPrefix("custom:") {
            return .custom(String(raw.dropFirst("custom:".count)))
        }
        switch raw {
        case "rewrite": return .rewrite
        case "summarize": return .summarize
        case "fix-grammar", "fixGrammar": return .fixGrammar
        default: return nil
        }
    }
}

/// Builds provider prompts from actions and input text.
enum PromptBuilder {
    /// The strict trailing instruction shared by every template.
    static let outputOnlyClause =
        "Output ONLY the resulting text. No preamble, no explanations, no quotes, no markdown fences."

    static func build(action: EditAction, text: String) -> String {
        let instruction: String
        switch action {
        case .rewrite:
            instruction = "Rewrite the following text to be clearer and more natural while preserving its meaning."
        case .summarize:
            instruction = "Summarize the following text concisely."
        case .fixGrammar:
            instruction = "Correct the spelling, grammar, and punctuation of the following text. Preserve the original meaning, tone, and language."
        case .custom(let request):
            instruction = "Apply the following instruction to the text below.\nInstruction: \(request)"
        }
        return """
        \(instruction)
        \(outputOnlyClause)

        TEXT:
        \(text)
        """
    }
}
