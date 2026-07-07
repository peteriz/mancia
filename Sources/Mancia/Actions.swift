import Foundation

/// A text-editing action the user can invoke from the panel.
///
/// `improve` is the panel's single hero action — a proofread + rewrite blend.
/// The other cases remain available through the debug CLI and prompt tests.
enum EditAction: Equatable, Sendable {
    case improve
    case rewrite
    case summarize
    case fixGrammar
    case custom(String)

    /// Short user-facing label for buttons/menus.
    var title: String {
        switch self {
        case .improve: return "Improve"
        case .rewrite: return "Rewrite"
        case .summarize: return "Summarize"
        case .fixGrammar: return "Proofread"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol name for the button.
    var symbol: String {
        switch self {
        case .improve: return "wand.and.rays"
        case .rewrite: return "pencil.and.outline"
        case .summarize: return "text.line.first.and.arrowtriangle.forward"
        case .fixGrammar: return "text.badge.checkmark"
        case .custom: return "sparkles"
        }
    }

    /// Present-participle label shown while the action runs ("Improving…").
    var progressLabel: String {
        switch self {
        case .improve: return "Improving"
        case .rewrite: return "Rewriting"
        case .summarize: return "Summarizing"
        case .fixGrammar: return "Proofreading"
        case .custom: return "Working"
        }
    }

    /// Parse the CLI/debug identifier for an action ("fix-grammar", "custom:...").
    static func parse(_ raw: String) -> EditAction? {
        if raw.hasPrefix("custom:") {
            return .custom(String(raw.dropFirst("custom:".count)))
        }
        switch raw {
        case "improve": return .improve
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
        "Return only the resulting text. Do not include a preamble, explanation, quotation marks, or Markdown code fence."

    static let rewriteTemplate = PromptTemplate(
        task: "Rewrite the text for clarity, flow, and natural phrasing.",
        requirements: [
            "Preserve the meaning, factual details, tone, language, and formatting.",
            "Do not add information, examples, claims, or opinions.",
            "Keep the result close to the original length unless a shorter version is clearer.",
        ]
    )

    static let summarizeTemplate = PromptTemplate(
        task: "Summarize the text.",
        requirements: [
            "Keep the main point, key decisions, names, numbers, dates, and constraints.",
            "Remove repetition, examples, and supporting detail unless needed for accuracy.",
            "Use clear, concise language in the same language as the source text.",
        ]
    )

    static let proofreadTemplate = PromptTemplate(
        task: "Proofread the text.",
        requirements: [
            "Fix spelling, grammar, punctuation, capitalization, and obvious typos.",
            "Preserve the meaning, tone, language, formatting, line breaks, and wording as much as possible.",
            "Change only what is needed for correctness.",
        ]
    )

    static let improveTemplate = PromptTemplate(
        task: "Improve the wording, grammar, and clarity of the text so it reads better and more naturally.",
        requirements: [
            "Preserve the meaning, factual details, intent, tone, language, and formatting.",
            "Fix spelling, grammar, punctuation, and awkward or unnatural phrasing.",
            "Do not add new information or remove any.",
        ]
    )

    static func build(action: EditAction, text: String) -> String {
        switch action {
        case .improve:
            return improveTemplate.render(text: text)
        case .rewrite:
            return rewriteTemplate.render(text: text)
        case .summarize:
            return summarizeTemplate.render(text: text)
        case .fixGrammar:
            return proofreadTemplate.render(text: text)
        case .custom(let request):
            return PromptTemplate.custom(request: request).render(text: text)
        }
    }
}

/// A single editable prompt template for an action.
struct PromptTemplate: Equatable, Sendable {
    let task: String
    let requirements: [String]
    let userInstruction: String?

    init(task: String, requirements: [String], userInstruction: String? = nil) {
        self.task = task
        self.requirements = requirements
        self.userInstruction = userInstruction
    }

    static func custom(request: String) -> PromptTemplate {
        PromptTemplate(
            task: "Apply the user instruction to the input text.",
            requirements: [
                "Follow the user instruction exactly, without adding unrelated changes.",
                "Preserve any content, details, formatting, tone, and language not targeted by the instruction.",
                "If the instruction asks for a format change, apply only that format change.",
            ],
            userInstruction: request
        )
    }

    func render(text: String) -> String {
        var sections = [
            """
        Task:
        \(task)
        """,
        ]

        if let userInstruction {
            sections.append(
                """
                User instruction:
                <<<
                \(userInstruction)
                >>>
                """
            )
        }

        sections.append(
            """
        Requirements:
        \(requirements.map { "- \($0)" }.joined(separator: "\n"))
        - \(PromptBuilder.outputOnlyClause)
        """
        )

        sections.append(
            """
        Input text:
        <<<
        \(text)
        >>>
        """
        )

        return sections.joined(separator: "\n\n")
    }
}
