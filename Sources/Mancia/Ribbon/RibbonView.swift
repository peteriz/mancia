import AppKit
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
    /// False for the off-screen copy `RibbonWindow` measures against. That copy
    /// must not ask for a resize (it would recurse) and must not speak to
    /// VoiceOver (the user would hear everything twice).
    var isLive = true
    /// Tell the window the lane wants to be a different height.
    var onLayoutChange: () -> Void = {}

    /// Mirrors `model.focusedCell`. The model is the source of truth because
    /// Tab arrives at the window rather than at a view.
    @FocusState private var focus: PanelModel.Cell?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The command row's fixed height. Everything below it — the status strip,
    /// the review region — is added by later phases and grows the lane
    /// downward.
    private let rowHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            commandRow
            statusStrip
            if model.phase == .confirm {
                hairline
                RibbonReviewView(model: model)
            }
        }
        .frame(width: width)
        .background(RibbonPalette.lane)
        .clipShape(shape)
        .overlay(shape.strokeBorder(RibbonPalette.laneEdge, lineWidth: 1))
        .onExitCommand { model.onCancel?() }
        // Without this, SwiftUI picks its own initial focus when the lane
        // becomes key — the Action menu, in practice — and it does so *after*
        // `focusDirection` has run, so the model's choice loses the race and
        // the first thing typed goes nowhere.
        .defaultFocus($focus, .direction)
        .onAppear { focus = model.focusedCell }
        .onChange(of: model.sessionSeq) { focusDirection() }
        .onChange(of: model.focusSeq) { focusDirection() }
        .onChange(of: model.focusedCell) { adopt(model.focusedCell) }
        .onChange(of: focus) { if let focus, isLive { model.focusedCell = focus } }
        .onChange(of: model.phase) { announcePhase(); relayout(); adopt(model.focusedCell) }
        .onChange(of: model.capturing) { relayout() }
        .onChange(of: model.versionCount) { relayout() }
        .onChange(of: model.previewExpanded) { relayout() }
        .onChange(of: model.errorDetailsExpanded) { relayout() }
        .onChange(of: model.errorText) { relayout() }
    }

    /// A lane flush against the top of the screen rounds only its bottom
    /// corners; parked against the bottom it rounds only its top corners; a
    /// window-anchored one floats over the host and rounds all four.
    private var shape: UnevenRoundedRectangle {
        switch anchor {
        case .screen:
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous)
        case .screenBottom:
            UnevenRoundedRectangle(
                topLeadingRadius: 12, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous)
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
            Group {
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
            }
            .opacity(locked ? 0.5 : 1)
            .disabled(locked)

            divider

            runControl
                .padding(.horizontal, 12)
        }
        .frame(height: rowHeight)
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
                    Button("Selection · \(model.selectionCharCount)") {
                        model.setScope(.selection)
                        model.returnFocusToDirection()
                    }
                    Button("Entire document") {
                        model.setScope(.document)
                        model.returnFocusToDirection()
                    }
                } label: {
                    menuLabel(targetText)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable()
                .focused($focus, equals: .target)
                .ribbonFocusRing(focus == .target)
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
                        model.returnFocusToDirection()
                    } label: {
                        Label(preset.title, systemImage: preset.action.symbol)
                    }
                }
                Divider()
                Button("Your instruction") {
                    model.pinnedPreset = nil
                    model.returnFocusToDirection()
                }
            } label: {
                menuLabel(model.resolvedActionTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable()
            .focused($focus, equals: .action)
            .ribbonFocusRing(focus == .action)
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
                .focused($focus, equals: .direction)
                .ribbonFocusRing(focus == .direction, inset: -2)
                .onSubmit { model.runPrimary() }
                .accessibilityLabel("Direction")
                .accessibilityIdentifier("CustomInstruction")
        }
    }

    /// The lane's one vermilion control, and the only one on this surface.
    ///
    /// While a request runs the comet rides this border — the panel wore it on
    /// its instruction field, but here Run is what the user is waiting on. The
    /// fill and label dim with the rest of the row; the comet does not, or the
    /// working signal would be the faintest thing on the lane.
    private var runControl: some View {
        Button { model.runPrimary() } label: {
            Text("Run ↵")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RibbonPalette.onAction)
                .frame(minWidth: 84, minHeight: 32)
        }
        .buttonStyle(.plain)
        // The fill and the running border hang off the button rather than off
        // its label: a `Text` wrapped in a background is rendered as an image,
        // and an image-backed button has no accessible name to override.
        .background(runShape.fill(RibbonPalette.action))
        .opacity(locked ? 0.5 : 1)
        .overlay {
            if model.phase == .running {
                SwooshBorder(shape: runShape, tint: RibbonPalette.action, animated: !reduceMotion)
            }
        }
        .contentShape(runShape)
        .focusable()
        .focused($focus, equals: .run)
        .ribbonFocusRing(focus == .run, radius: 8, inset: -3)
        .disabled(locked)
        .help(model.resolvedActionTitle)
        // The visible glyph is a keyboard hint, not a word.
        .accessibilityLabel("Run")
        .accessibilityValue(model.resolvedActionTitle)
        .accessibilityIdentifier("Run")
    }

    private var runShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
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

// MARK: - Status strip

extension RibbonView {
    /// One line under the command row naming what the session is doing and
    /// carrying that phase's secondary actions. Hidden at rest, because a
    /// resting lane has nothing to report that the command row does not already
    /// say.
    @ViewBuilder
    fileprivate var statusStrip: some View {
        switch model.phase {
        case .idle:
            if model.capturing {
                strip { statusLabel("Reading selection…", dot: RibbonPalette.caption) }
            }
        case .running:
            strip {
                statusLabel("\(runningLabel)…", dot: RibbonPalette.caption)
                Spacer(minLength: 8)
                GhostButton("Cancel", tint: RibbonPalette.caption) { model.onCancelRun?() }
                    .accessibilityIdentifier("Cancel")
            }
        case .confirm:
            // The review region below carries the question, the delta and the
            // decision; a strip repeating them would be noise.
            EmptyView()
        case .applied:
            strip {
                statusLabel("Improved", dot: RibbonPalette.applied, tint: RibbonPalette.applied)
                Spacer(minLength: 8)
                if model.versionCount > 1 {
                    VersionNav(
                        model: model, tint: RibbonPalette.caption,
                        faint: RibbonPalette.caption.opacity(0.45))
                }
            }
        case .error:
            VStack(alignment: .leading, spacing: 0) {
                strip {
                    statusLabel(errorLabel, dot: RibbonPalette.error, tint: RibbonPalette.error)
                    Spacer(minLength: 8)
                    GhostButton(
                        model.errorDetailsExpanded ? "Hide details" : "Details",
                        tint: RibbonPalette.caption
                    ) {
                        model.errorDetailsExpanded.toggle()
                    }
                    .accessibilityIdentifier("ErrorDetails")
                    GhostButton("Copy", tint: RibbonPalette.caption) { copyError() }
                        .accessibilityIdentifier("CopyError")
                    GhostButton("Retry", tint: RibbonPalette.error) { model.onRetry?() }
                        .accessibilityIdentifier("Retry")
                }
                if model.errorDetailsExpanded {
                    errorDetails
                }
            }
        }
    }

    private func strip(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            hairline
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
    }

    fileprivate var hairline: some View {
        Rectangle().fill(RibbonPalette.laneEdge).frame(height: 1)
    }

    private func statusLabel(
        _ text: String, dot: Color, tint: Color = RibbonPalette.caption
    ) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            // The dot never carries the state alone; the words always name it.
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    /// The verb shown while a request runs. Stays honest during the brief
    /// background-capture window before the provider call begins.
    private var runningLabel: String {
        if model.capturing { return "Reading selection" }
        return model.runningTitle.isEmpty ? "Improving" : model.runningTitle
    }

    private var errorLabel: String {
        model.errorText.isEmpty ? "Provider failed" : model.errorText
    }

    /// The full failure text, which the one-line strip truncates. Five lines
    /// before it starts scrolling — enough for a provider's stderr without the
    /// lane turning into a console.
    private var errorDetails: some View {
        ScrollView {
            Text(errorLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(RibbonPalette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 5 * 15)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// A deliberate copy, so it goes straight to the pasteboard. Routing it
    /// through `SelectionCapture`'s snapshot/restore machinery would be wrong:
    /// that exists to protect the user's clipboard *during* an edit cycle.
    private func copyError() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(errorLabel, forType: .string)
    }

    // MARK: - Announcements

    /// The strip is a live region: VoiceOver users should hear the phase
    /// change, not have to go looking for it.
    fileprivate func announcePhase() {
        guard isLive, let announcement = phaseAnnouncement else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private var phaseAnnouncement: String? {
        switch model.phase {
        case .idle: return nil
        case .running: return "\(runningLabel)"
        case .confirm: return "Replace entire document?"
        case .applied: return "Improved"
        case .error: return errorLabel
        }
    }

    fileprivate func relayout() {
        guard isLive else { return }
        onLayoutChange()
    }

    // MARK: - Focus

    /// Put focus back in Direction — on open, and whenever the lane retakes
    /// key status.
    fileprivate func focusDirection() {
        model.focusedCell = .direction
        adopt(.direction)
    }

    /// Take the model's focus and hand it to SwiftUI, one turn later.
    ///
    /// Deferred because the cell may still be disabled in the update that
    /// changed the phase; SwiftUI drops focus on a disabled control, so
    /// claiming it in the same turn would be undone immediately.
    fileprivate func adopt(_ cell: PanelModel.Cell) {
        guard isLive else { return }
        Task { @MainActor in
            guard model.focusedCell == cell else { return }
            focus = cell
        }
    }
}
