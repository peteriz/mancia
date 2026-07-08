import Foundation

/// Validation failures for the open prompt gate, each with user-facing guidance.
enum PromptGuardError: LocalizedError, Equatable {
    case emptyInput
    case emptyInstruction
    case instructionTooLong(limit: Int)
    case inputTooLong(limit: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "There is no text to edit."
        case .emptyInstruction:
            return "Type an instruction describing the change you want."
        case .instructionTooLong(let limit):
            return "That instruction is too long (limit \(limit) characters). Shorten it and try again."
        case .inputTooLong(let limit):
            return "The selected text is too large to edit (limit \(limit) characters). Select a smaller portion."
        }
    }
}

/// Pure, testable bounds-checking for the untrusted input text and the
/// free-form user instruction before either reaches the provider.
///
/// This is a resource-abuse guard, not a content filter: the provider already
/// runs sandboxed with every agent tool disabled (`--available-tools=`), so the
/// meaningful risks here are a runaway selection (cost/latency) and a
/// pathological instruction. Keeping the checks pure keeps them unit-testable
/// and reusable across the panel flow and the debug CLI.
enum PromptGuard {
    /// Max characters for a free-form instruction. Generous for real edits.
    static let maxInstructionCharacters = 2_000
    /// Max characters of text to edit in a single request (~25k tokens).
    static let maxInputCharacters = 100_000

    /// Validate a free-form user instruction. Returns the trimmed instruction.
    @discardableResult
    static func validateInstruction(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PromptGuardError.emptyInstruction }
        guard trimmed.count <= maxInstructionCharacters else {
            throw PromptGuardError.instructionTooLong(limit: maxInstructionCharacters)
        }
        return trimmed
    }

    /// Validate the text to edit. Returns it unchanged — surrounding whitespace,
    /// line breaks, and formatting are all significant to an inline edit.
    @discardableResult
    static func validateInput(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptGuardError.emptyInput
        }
        guard text.count <= maxInputCharacters else {
            throw PromptGuardError.inputTooLong(limit: maxInputCharacters)
        }
        return text
    }

    /// Validate everything an action needs before its prompt is built: the input
    /// text always, plus the instruction when the action is `.custom`.
    static func validate(action: EditAction, text: String) throws {
        if case .custom(let request) = action {
            try validateInstruction(request)
        }
        try validateInput(text)
    }
}
