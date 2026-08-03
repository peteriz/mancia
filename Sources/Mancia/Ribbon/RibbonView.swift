import AppKit
import SwiftUI

/// The command ribbon — a slim lane that opens against the text being edited:
/// just under the selection, or just over it when the selection sits too near
/// the foot of its window. With no selection to sit against, or no room beside
/// one, it falls back to a predictable resting place at the top — under the
/// menu bar, or under the frontmost window's title bar. See `RibbonPlacement`.
///
/// The lane reads left to right as one sentence: **Target · Actions · Run**.
/// All five actions are visible; selecting Custom moves it to the leading edge
/// and discloses Direction beside it. The cells carry no captions: they were
/// the first
/// thing to go when the row was collapsed to one line, and the resolved action
/// is spelled out in the Action chip itself instead — which is what the panel
/// this replaces got wrong by leaving "an empty field means Improve" implicit.
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
    ///
    /// It is a mirror, not the ring's input. SwiftUI grants `@FocusState` to
    /// Direction and refuses it to the `.focusable()` cells, so
    /// Tab left the ring stuck on the field while the model — and therefore
    /// Return, which the window routes by `focusedCell` — had already moved on.
    /// The ring reads the model, which is the stop the keyboard is actually on.
    @FocusState private var focus: PanelModel.Cell?
    @State private var hoveredAction: Int?
    @State private var runHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The height of every control on the command row, and so the height the
    /// row rests at once its padding is added.
    private let controlHeight: CGFloat = 32
    /// The command row's resting height. It grows when the Direction field
    /// wraps, and everything below it — the failure strip, the review
    /// region — is added by later phases and grows the lane further downward.
    private let rowHeight: CGFloat = 48
    /// Room for the widest Target value so it does not resize mid-session.
    private let targetMinWidth: CGFloat = 132

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
        // becomes key — the first action button, in practice — after
        // `focusPrimaryControl` has run, so the model's choice loses the race.
        .defaultFocus($focus, .run)
        .onAppear { focus = model.focusedCell }
        .onChange(of: model.sessionSeq) { focusPrimaryControl() }
        .onChange(of: model.focusSeq) { focusPrimaryControl() }
        .onChange(of: model.focusedCell) { adopt(model.focusedCell) }
        .onChange(of: focus) { if let focus, isLive { model.focusedCell = focus } }
        .onChange(of: model.phase) {
            runHovered = false
            announcePhase()
            relayout()
            adopt(model.focusedCell)
        }
        .onChange(of: model.capturing) { relayout() }
        // The Direction field wraps to four lines, so what the user types is a
        // height input like any other.
        .onChange(of: model.instruction) { relayout() }
        .onChange(of: model.isCustomInstructionSelected) {
            hoveredAction = nil
            relayout()
        }
        .onChange(of: model.previewExpanded) { relayout() }
        .onChange(of: model.errorDetailsExpanded) { relayout() }
        .onChange(of: model.errorText) { relayout() }
    }

    /// A lane flush against the top of the screen rounds only its bottom
    /// corners; one floating over the host or against the selection rounds all
    /// four.
    private var shape: UnevenRoundedRectangle {
        switch anchor {
        case .screen:
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 0, style: .continuous)
        case .hostWindow, .belowSelection, .aboveSelection, .leftOfSelection, .rightOfSelection:
            UnevenRoundedRectangle(
                topLeadingRadius: 12, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
        }
    }

    /// The command row stays visible and readable while a request runs. Target
    /// and action selection go inert; the primary button stays live as Cancel.
    private var locked: Bool { model.phase == .running || model.phase == .confirm }

    // MARK: - Command row

    /// One line, read left to right: **Target · five Actions**, then the trailing
    /// primary action. Custom inserts Direction immediately after itself.
    ///
    /// Each cell used to carry a caption above its value. They were the widest
    /// thing on the lane and said the least: "Selection · 22", "Improve" and a
    /// prompted field all name themselves, so the captions only repeated the
    /// answer in smaller type. Dropping them collapsed the row from two lines
    /// to one and let every control size to its own content instead of to a
    /// fixed width chosen to fit a label.
    private var commandRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                targetCell
                actionStrip
            }
            .opacity(locked ? 0.5 : 1)
            .disabled(locked)

            // The field stops at its cap and this takes the rest, keeping what
            // the user typed from rewrapping underneath them.
            if model.isCustomInstructionSelected {
                Spacer(minLength: 0)
            }

            trailingCluster
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: rowHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: model.isCustomInstructionSelected)
    }

    // MARK: - Cells

    /// What the edit will touch. A menu while there is a selection to choose
    /// between; a static chip when the whole document is the only option.
    ///
    /// The chip is terse — an icon, one word and the character count — because
    /// it is the least interesting cell on a lane the user came to type in. The
    /// menu it opens keeps the unabbreviated wording, where there is room for
    /// it and the choice has to be unambiguous.
    @ViewBuilder
    private var targetCell: some View {
        if model.capturing {
            chip {
                chipLabel("ellipsis", "Reading…", chevron: false, minWidth: targetMinWidth)
            }
            .accessibilityLabel("Target, reading selection")
            .accessibilityIdentifier("Target")
        } else if model.hasSelection {
            Menu {
                Button("Selection · \(model.selectionCharCount)") {
                    model.setScope(.selection)
                    model.returnFocusToPrimaryControl()
                }
                Button("Entire document") {
                    model.setScope(.document)
                    model.returnFocusToPrimaryControl()
                }
                Divider()
                // A hint, not a binding. `KeyablePanel` resolves ⌘T above the
                // SwiftUI tree and consumes it, so this item never fires; it is
                // here because the menu is where someone looks for the key.
                Text("⌘T switches")
            } label: {
                targetLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            // The fill hangs off the menu, not off its label: a `Text` wrapped
            // in a background is rendered as an image, and an image-backed
            // control has no accessible name left to override.
            .background(controlShape.fill(RibbonPalette.control))
            .focusable()
            .focused($focus, equals: .target)
            .ribbonFocusRing(model.focusedCell == .target, radius: 8, inset: 0)
            .accessibilityLabel("Target")
            .accessibilityValue(targetSpokenValue)
            .accessibilityIdentifier("Scope")
        } else {
            chip {
                chipLabel("doc.text", "Document", chevron: false, minWidth: targetMinWidth)
            }
            .accessibilityLabel("Target")
            .accessibilityValue("Entire document")
            .accessibilityIdentifier("Target")
        }
    }

    @ViewBuilder
    private var targetLabel: some View {
        switch model.scope {
        case .selection:
            chipLabel(
                "selection.pin.in.out", "Selection", detail: "\(model.selectionCharCount)",
                minWidth: targetMinWidth)
        case .document:
            chipLabel("doc.text", "Document", minWidth: targetMinWidth)
        }
    }

    /// VoiceOver hears the count and the unabbreviated noun; the chip shows the
    /// short form.
    private var targetSpokenValue: String {
        switch model.scope {
        case .selection: return "Selection, \(model.selectionCharCount) characters"
        case .document: return "Entire document"
        }
    }

    /// Stable identities let SwiftUI slide Custom from the trailing edge to the
    /// leading edge instead of replacing it. The 4pt gap and 8pt button padding
    /// keep five named controls usable at the compact ribbon width.
    private var actionStrip: some View {
        HStack(spacing: 4) {
            ForEach(model.actionDisplayOrder, id: \.self) { index in
                actionButton(at: index)
                if index == PanelModel.customActionIndex,
                   model.isCustomInstructionSelected
                {
                    directionCell
                        .transition(directionTransition)
                }
            }
        }
    }

    private func actionButton(at index: Int) -> some View {
        let title = model.actionTitle(at: index) ?? ""
        let shortcut = model.actionShortcut(at: index) ?? ""
        let selected = model.isActionSelected(at: index)
        let isHovered = hoveredAction == index
        return Button { model.activateAction(at: index) } label: {
            ZStack {
                Text(title).opacity(isHovered ? 0 : 1)
                Text(shortcut).opacity(isHovered ? 1 : 0)
            }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RibbonPalette.text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background(
            controlShape.fill(selected ? RibbonPalette.controlSelected : RibbonPalette.control))
        .overlay(
            controlShape.strokeBorder(
                selected ? RibbonPalette.action.opacity(0.65) : RibbonPalette.laneEdge,
                lineWidth: 1))
        .focusable()
        .focused($focus, equals: .action(index))
        .ribbonFocusRing(model.focusedCell == .action(index), radius: 8, inset: 0)
        .help("\(title) (\(shortcut))")
        .onHover { isHovering in
            guard isLive else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                if isHovering {
                    hoveredAction = index
                } else if hoveredAction == index {
                    hoveredAction = nil
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(index == PanelModel.customActionIndex
            ? "Command \(index + 1). Opens the custom instruction field."
            : "Command \(index + 1). Runs immediately.")
        .accessibilityIdentifier("Action-\(index + 1)")
    }

    /// The instruction field, disclosed only for Custom.
    ///
    /// It is the one cell that takes the lane's slack, and the only one that
    /// grows: past a line it wraps and pushes the lane downward, to four lines
    /// and then a scroller. The cap is roughly the 70-character measure that
    /// reads comfortably — past that the field was simply absorbing the lane,
    /// which is what made it look like the most important thing on a surface
    /// where it is optional. A caption above it would have been a third name
    /// for a control that already carries a prompt inside it and lights its
    /// border when it has focus.
    private var directionCell: some View {
        TextField("", text: $model.instruction, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(directionFont)
            .foregroundStyle(RibbonPalette.text)
            .focused($focus, equals: .direction)
            .onSubmit { model.runPrimary() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .topLeading) { placeholder }
            .frame(minWidth: 140, maxWidth: 460, alignment: .leading)
            .frame(minHeight: controlHeight, alignment: .topLeading)
            .background(controlShape.fill(RibbonPalette.control))
            // Past four lines the field scrolls, and without this the line
            // sliding out of view draws over the field's own top edge.
            .clipShape(controlShape)
            .overlay(controlShape.strokeBorder(RibbonPalette.laneEdge, lineWidth: 1))
            .ribbonFocusRing(model.focusedCell == .direction, radius: 8, inset: 0)
            .accessibilityLabel("Direction")
            .accessibilityIdentifier("CustomInstruction")
    }

    private var directionTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .modifier(
            active: HorizontalReveal(progress: 0),
            identity: HorizontalReveal(progress: 1))
    }

    private var directionFont: Font { .system(size: 13, weight: .medium) }

    // MARK: - Trailing cluster

    /// The selected action lives in one fixed-width control. During a request,
    /// that same control becomes Cancel on hover, so no adjacent status or
    /// secondary action can resize the regular buttons-only state.
    private var trailingCluster: some View {
        runControl.frame(height: controlHeight)
    }

    /// The lane's one vermilion control, and the only one on this surface.
    ///
    /// While a request runs the comet rides this border — the panel wore it on
    /// its instruction field, but here Run is what the user is waiting on.
    /// Going inert softens the fill only. Dark ink on a bright fill does not
    /// survive being dimmed: both ends walk toward the lane together and the
    /// label's contrast collapses to about 2.5:1, which is how the one word on
    /// the lane's one accent control became the least readable thing on it.
    private var runControl: some View {
        Button {
            if model.phase == .running {
                model.onCancelRun?()
            } else {
                model.runPrimary()
            }
        } label: {
            // Invisible, not hidden and not absent: the button still takes its
            // size from the real label, so the two cannot drift apart, and the
            // drawn word is the overlay below. `hidden()` would be the obvious
            // way to say this and is the wrong one — a hidden view takes no
            // hits, and a plain button's hit region *is* its label, so the one
            // control the lane is named for quietly stopped answering the
            // mouse. `contentShape` has to ride inside the label for the same
            // reason: outside the button it shapes the wrapper, not the region
            // the button's own gesture watches.
            runLabel
                .opacity(0)
                .frame(width: 96)
                .frame(minHeight: controlHeight)
                .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        // The fill and the running border hang off the button rather than off
        // its label: a `Text` wrapped in a background is rendered as an image,
        // and an image-backed button has no accessible name to override.
        .background(controlShape.fill(runDisabled ? RibbonPalette.actionInert : RibbonPalette.action))
        .overlay {
            if model.phase == .running {
                // The head is light, not vermilion: the comet is riding the
                // one control on the lane already filled with the tint, and a
                // vermilion head there had nothing to be brighter than. The
                // tail and the halo stay vermilion, so the lane still spends
                // its accent exactly once.
                SwooshBorder(
                    shape: controlShape,
                    tint: RibbonPalette.action,
                    animated: !reduceMotion,
                    head: RibbonPalette.text,
                    halo: 4,
                    lineWidth: 2.5
                )
                .allowsHitTesting(false)
            }
        }
        .contentShape(controlShape)
        .focusable()
        .focused($focus, equals: .run)
        .ribbonFocusRing(model.focusedCell == .run, radius: 8, inset: -3)
        .disabled(runDisabled)
        // Drawn *after* `disabled`, and so outside the subtree it dims.
        // SwiftUI fades a disabled button's label whatever style it wears, and
        // that fade is the collapse described above; the softened fill is the
        // signal instead. `disabled` still owns the behaviour — no hit
        // testing, out of the focus chain, dimmed to VoiceOver.
        .overlay {
            runLabel
                .frame(maxWidth: .infinity, minHeight: controlHeight)
                .allowsHitTesting(false)
        }
        .help(runHelp)
        .onHover { isHovering in
            guard isLive else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                runHovered = model.phase == .running && isHovering
            }
        }
        .accessibilityLabel(runAccessibilityLabel)
        .accessibilityValue(runAccessibilityValue)
        .accessibilityIdentifier("Run")
    }

    private var runLabel: some View {
        Text(runLabelText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RibbonPalette.onAction)
            .lineLimit(1)
    }

    private var runLabelText: String {
        if runHovered, let hoverTitle = model.runButtonHoverTitle { return hoverTitle }
        return model.runButtonTitle
    }

    private var runHelp: String {
        switch model.phase {
        case .running: return "Cancel \(runningLabel)"
        default: return model.runButtonTitle
        }
    }

    private var runAccessibilityLabel: String {
        switch model.phase {
        case .running: return "Cancel \(model.resolvedActionTitle)"
        default: return model.runButtonTitle
        }
    }

    private var runAccessibilityValue: String {
        model.phase == .running ? runningLabel : model.resolvedActionTitle
    }

    private var runDisabled: Bool {
        model.phase == .confirm || (model.phase != .running && !model.canRunPrimary)
    }

    // MARK: - Control chrome

    /// One radius for every control on the lane.
    private var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    /// A non-interactive control-shaped surface, for the states where the
    /// Target cell has nothing to offer a menu.
    ///
    /// `fixedSize` matches what `.fixedSize()` does for the menu branch: the
    /// label carries a trailing spacer so its `minWidth` reservation pushes
    /// left, and without the clamp that spacer would let the chip swallow every
    /// point of slack the row has.
    private func chip(@ViewBuilder content: () -> some View) -> some View {
        content()
            .fixedSize()
            .background(controlShape.fill(RibbonPalette.control))
            .accessibilityElement(children: .combine)
    }

    /// Icon, value and — when the control opens a menu — a disclosure chevron.
    /// The icon does the work the caption used to: it says which cell this is
    /// before the value says what it holds.
    ///
    /// `minWidth` reserves room for the widest thing a cell can say. Without it
    /// the row shuffles sideways mid-use — the Action chip alone grows by some
    /// 50pt the instant the user types a first character, dragging the field
    /// they are typing in along with it.
    private func chipLabel(
        _ symbol: String, _ title: String, detail: String? = nil, chevron: Bool = true,
        minWidth: CGFloat = 0
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RibbonPalette.caption)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RibbonPalette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(RibbonPalette.caption)
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(RibbonPalette.caption)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: minWidth, alignment: .leading)
        .frame(height: controlHeight)
        .contentShape(Rectangle())
    }

    /// The field's own prompt, drawn rather than handed to `TextField`.
    ///
    /// SwiftUI resolves a `prompt`'s colour from the system placeholder
    /// register and ignores any foreground style put on the `Text`. The lane
    /// keeps a fixed dark register whatever the system appearance is, so in
    /// Light Mode that register resolved to near-black on the field's
    /// near-black fill — the prompt was there and unreadable. Drawing it makes
    /// the colour ours, and the 5.13:1 against `control` that `RibbonPalette`
    /// documents true rather than aspirational.
    @ViewBuilder
    private var placeholder: some View {
        if model.instruction.isEmpty {
            Text("Optional instruction…")
                .font(directionFont)
                .foregroundStyle(RibbonPalette.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Status strip

extension RibbonView {
    /// The one phase that still earns a row of its own.
    ///
    /// Reading lives in Target; working and done live in the primary button. A
    /// failure cannot: it carries a provider message too long for the command
    /// row and three recoveries to offer, and it is the one state where taking
    /// the user's attention is the point.
    @ViewBuilder
    fileprivate var statusStrip: some View {
        if model.phase == .error {
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

    private func statusLabel(
        _ text: String, dot: Color, tint: Color = RibbonPalette.caption
    ) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    fileprivate var hairline: some View {
        Rectangle().fill(RibbonPalette.laneEdge).frame(height: 1)
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

    /// Put focus on the control that completes the selected action — on open,
    /// and whenever the lane retakes key status.
    fileprivate func focusPrimaryControl() {
        let cell = model.primaryFocusCell
        model.focusedCell = cell
        adopt(cell)
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

/// A field transition that grows only along the row, from the Action side. The
/// surrounding HStack animates its layout in the same short transaction.
private struct HorizontalReveal: @preconcurrency AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            // Never scale the actual AppKit-backed TextField to zero. A zero
            // x-scale makes its descendant transform non-invertible just as
            // focus installs the field editor, which trips AppKit's
            // `CGAffineTransformIsSingular` assertion. Reveal through a mask
            // instead: the field keeps stable geometry while the visible slice
            // still grows quickly from left to right.
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .frame(width: geometry.size.width * progress)
                }
            }
            .opacity(progress)
            .clipped()
    }
}
