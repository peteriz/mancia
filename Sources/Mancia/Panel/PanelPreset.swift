import Foundation

/// A specialized editing prompt offered by the panel field's dropdown.
///
/// A preset pairs a named `EditAction` (which carries the specialized
/// `PromptTemplate`) with the copy shown in the menu. Anything typed in the
/// instruction field rides along as additional guidance for the preset — see
/// `PanelModel.runPreset(_:)`.
///
/// The list is intentionally short: presets are the handful of edits worth a
/// one-click affordance, not a catalogue. Adding one means appending an entry
/// here and, if it needs its own wording, a template in `Actions.swift`.
struct PanelPreset: Identifiable, Equatable, Sendable {
    let id: String
    /// Menu title.
    let title: String
    let action: EditAction

    static let improve = PanelPreset(id: "improve", title: "Improve", action: .improve)
    static let sharpen = PanelPreset(id: "sharpen", title: "Sharpen", action: .sharpen)
    static let planFirst = PanelPreset(id: "plan-first", title: "Plan first", action: .planFirst)
    static let tighten = PanelPreset(id: "tighten", title: "Tighten", action: .tighten)

    /// The presets the field dropdown offers, in menu order (most-used first).
    ///
    /// Improve is the general prose pass; the other three target text written
    /// for coding agents — restructure it, reframe it as a planning request, or
    /// compress it without losing requirements.
    static let all: [PanelPreset] = [.improve, .sharpen, .planFirst, .tighten]
}
