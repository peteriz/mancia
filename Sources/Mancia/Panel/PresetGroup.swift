import Foundation

/// A named set of presets the action strip shows together.
///
/// The strip has room for exactly `PresetGroup.slotCount` presets plus Custom,
/// and keys 1…4 address them by position, so every group fills every slot.
/// Switching groups swaps the buttons in place; Custom keeps the last slot.
struct PresetGroup: Identifiable, Equatable, Sendable {
    let id: String
    /// Switcher label.
    let title: String
    let symbol: String
    /// One line for the switcher's tooltip.
    let summary: String
    let presets: [PanelPreset]

    /// Built-in buttons per group, ahead of Custom.
    static let slotCount = 4

    /// Text written for coding agents: a general prose pass, then restructure
    /// it, reframe it as a planning request, or compress it without losing
    /// requirements.
    static let prompt = PresetGroup(
        id: "prompt",
        title: "Prompt",
        symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Actions for text written to coding agents",
        presets: [.improve, .sharpen, .planFirst, .tighten])

    /// Prose written for people: correct it, strip AI tells, make it
    /// unambiguous for any reader, or give it Markdown structure.
    static let writing = PresetGroup(
        id: "writing",
        title: "Writing",
        symbol: "text.alignleft",
        summary: "Actions for prose written to people",
        presets: [.proofread, .unslop, .ste, .markdown])

    /// Switcher order. The first group is the default.
    static let all: [PresetGroup] = [.prompt, .writing]

    static func group(id: String?) -> PresetGroup {
        all.first { $0.id == id } ?? all[0]
    }

    /// The group after this one, wrapping.
    var next: PresetGroup {
        let index = Self.all.firstIndex(of: self) ?? 0
        return Self.all[(index + 1) % Self.all.count]
    }
}
