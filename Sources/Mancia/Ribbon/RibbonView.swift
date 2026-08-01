import SwiftUI

/// The command ribbon — a slim lane that opens in one predictable place at the
/// top of the screen, rather than next to the caret.
///
/// The lane reads left to right as one sentence: **Target · Action · Direction
/// · Run**. Each cell carries a caption above a value, so the resolved action
/// is legible at all times; the panel this replaces left "an empty field means
/// Improve" entirely implicit.
///
/// The lane's width is imposed by `RibbonPlacement`; its height comes from its
/// content, which is the opposite of how the floating panel sizes itself.
/// `RibbonWindow` measures this view at the resolved width and sets the window
/// frame from the result, so `width` is passed in rather than inferred.
struct RibbonView: View {
    @Bindable var model: PanelModel
    /// The width placement resolved for this session.
    let width: CGFloat
    /// Which edge the lane hangs from, which drives the corner treatment.
    let anchor: RibbonPlacement.Anchor

    @FocusState private var fieldFocused: Bool

    /// The command row's fixed height. Everything below it — the status strip,
    /// the review region — is added by later phases and grows the lane
    /// downward.
    private let rowHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            commandRow
        }
        .frame(width: width)
        .background(RibbonPalette.lane)
        .clipShape(shape)
        .overlay(shape.strokeBorder(RibbonPalette.laneEdge, lineWidth: 1))
        .onExitCommand { model.onCancel?() }
        .onAppear { fieldFocused = true }
        .onChange(of: model.sessionSeq) { fieldFocused = true }
        .onChange(of: model.focusSeq) { fieldFocused = true }
    }

    /// A screen-anchored lane hangs from the top edge and rounds only its
    /// bottom corners; a window-anchored one floats over the host and rounds
    /// all four.
    private var shape: UnevenRoundedRectangle {
        switch anchor {
        case .screen:
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous)
        case .hostWindow:
            UnevenRoundedRectangle(
                topLeadingRadius: 12, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
        }
    }

    /// The command row stays visible and readable while a request runs — the
    /// user can check what they asked for — but its controls go inert.
    private var locked: Bool { model.phase == .running || model.phase == .confirm }

    // MARK: - Command row

    private var commandRow: some View {
        HStack(spacing: 0) {
            targetCell
                .frame(width: 150, alignment: .leading)
                .padding(.leading, 16)
                .padding(.trailing, 12)

            divider

            actionCell
                .frame(width: 170, alignment: .leading)
                .padding(.horizontal, 12)

            divider

            directionCell
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

            divider

            runControl
                .padding(.horizontal, 12)
        }
        .frame(height: rowHeight)
        .opacity(locked ? 0.5 : 1)
        .disabled(locked)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    /// Stops short of the row's edges: a full-bleed divider makes the lane read
    /// as a table rather than as a sentence.
    private var divider: some View {
        Rectangle()
            .fill(RibbonPalette.laneEdge)
            .frame(width: 1, height: rowHeight - 20)
    }

    // MARK: - Cells

    /// What the edit will touch. A menu while there is a selection to choose
    /// between; a static label when the whole document is the only option.
    private var targetCell: some View {
        cell("Target") {
            if model.capturing {
                value(Text("Reading…"))
            } else if model.hasSelection {
                Menu {
                    Button("Selection · \(model.selectionCharCount)") { model.scope = .selection }
                    Button("Entire document") { model.scope = .document }
                } label: {
                    menuLabel(targetText)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Target")
                .accessibilityIdentifier("Scope")
            } else {
                value(Text("Entire document"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Target")
    }

    private var targetText: String {
        switch model.scope {
        case .selection: return "Selection · \(model.selectionCharCount)"
        case .document: return "Entire document"
        }
    }

    /// The action that will actually run, spelled out. The menu pins a preset
    /// explicitly; `Your instruction` unpins and hands the decision back to the
    /// Direction field.
    private var actionCell: some View {
        cell("Action") {
            Menu {
                ForEach(PanelPreset.all) { preset in
                    Button {
                        model.pinnedPreset = preset
                    } label: {
                        Label(preset.title, systemImage: preset.action.symbol)
                    }
                }
                Divider()
                Button("Your instruction") { model.pinnedPreset = nil }
            } label: {
                menuLabel(model.resolvedActionTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Action")
            .accessibilityIdentifier("Action")
        }
    }

    /// The instruction field. Optional by design — an empty Direction is a
    /// valid Improve, which is what the Action cell is there to say out loud.
    private var directionCell: some View {
        cell("Direction") {
            TextField("", text: $model.instruction, prompt: placeholder)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RibbonPalette.text)
                .focused($fieldFocused)
                .onSubmit { model.runPrimary() }
                .accessibilityLabel("Direction")
                .accessibilityIdentifier("CustomInstruction")
        }
    }

    /// The lane's one vermilion control, and the only one on this surface.
    private var runControl: some View {
        Button { model.runPrimary() } label: {
            Text("Run ↵")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RibbonPalette.onAction)
                .frame(minWidth: 84, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RibbonPalette.action)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(model.resolvedActionTitle)
        .accessibilityLabel("Run")
        .accessibilityIdentifier("Run")
    }

    // MARK: - Cell chrome

    /// Caption over value, the shape every cell shares.
    private func cell(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(RibbonPalette.caption)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ text: Text) -> some View {
        text
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(RibbonPalette.text)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            value(Text(title))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(RibbonPalette.caption)
        }
        .contentShape(Rectangle())
    }

    private var placeholder: Text {
        Text("Optional instruction…").foregroundColor(RibbonPalette.caption)
    }
}
