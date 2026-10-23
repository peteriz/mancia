import Foundation

/// A specialized editing prompt offered by the ribbon's action strip.
///
/// A preset pairs a named `EditAction` (which carries the specialized
/// `PromptTemplate`) with the copy shown on its button. Presets are offered in
/// groups — see `PresetGroup` — so adding one means defining it here, placing
/// it in a group, and, if it needs its own wording, a template in
/// `Actions.swift`.
struct PanelPreset: Identifiable, Equatable, Sendable {
    let id: String
    /// Button title.
    let title: String
    let action: EditAction

    // Prompt group: text written for coding agents.
    static let improve = PanelPreset(id: "improve", title: "Improve", action: .improve)
    static let sharpen = PanelPreset(id: "sharpen", title: "Sharpen", action: .sharpen)
    static let planFirst = PanelPreset(id: "plan-first", title: "Plan first", action: .planFirst)
    static let tighten = PanelPreset(id: "tighten", title: "Tighten", action: .tighten)

    // Writing group: prose written for people.
    static let proofread = PanelPreset(id: "proofread", title: "Proofread", action: .fixGrammar)
    static let unslop = PanelPreset(id: "unslop", title: "Unslop", action: .unslop)
    static let ste = PanelPreset(id: "ste", title: "STE", action: .ste)
    static let markdown = PanelPreset(id: "markdown", title: "Markdown", action: .markdown)
}
