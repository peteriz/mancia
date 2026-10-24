import AppKit
import SwiftUI

/// The command ribbon — one slim graphite panel that opens against the text
/// being edited: just under the selection, or just over it when the selection
/// sits too near the foot of the display. With no selection to sit against, or
/// no room beside one, it falls back to a predictable resting place at the top
/// — under the menu bar, or under the frontmost window's title bar. See
/// `RibbonPlacement`.
///
/// Everything lives on one row: the target, the action-set switch, then the
/// five actions. Custom
/// stays in that row and opens a field *downward*, in a drawer under it, so
/// the panel keeps one width in every state and only ever grows in height —
/// the axis placement already pins away from the selection.
///
/// The lane's width is imposed by `RibbonPlacement`; its height comes from its
/// content. `RibbonWindow` measures this view at the resolved width and sets
/// the window frame from the result, so `width` is passed in rather than
/// inferred.
struct RibbonView: View {
    @Bindable var model: PanelModel
    /// The width placement resolved for this session.
    let width: CGFloat
    /// Which edge the lane hangs from, which drives the corner treatment.
    let anchor: RibbonPlacement.Anchor
    /// The color the swoosh runs in while an action is in flight. Passed in
    /// as a resolved value rather than read from settings here, so the
    /// off-screen measurement copy and the live lane stay identical views.
    var swooshColor: Color = RibbonPalette.processing
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
    @State private var targetHovered = false
    @State private var presetGroupHovered = false
    @State private var customRunHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The height of every control on the command row.
    private let controlHeight: CGFloat = 32
    /// Inset between the lane's edge and its controls; also the gap the
    /// drawer keeps from the row above it.
    private let inset: CGFloat = 6
    private let laneRadius: CGFloat = 14
    /// Concentric with the lane: its radius less the inset.
    private var controlRadius: CGFloat { laneRadius - inset }

    var body: some View {
        ribbonWithLayoutObservers
    }

    private var ribbonSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            commandRow
            if showsCustomDrawer {
                customDrawer
                    .transition(drawerTransition)
            }
            statusStrip
            if model.phase == .scopeApproval {
                hairline
                RibbonScopeApprovalView(model: model, focus: $focus)
            }
        }
        .frame(width: width)
        .background(shape.fill(RibbonPalette.lane))
        .clipShape(shape)
        .overlay(shape.strokeBorder(RibbonPalette.laneEdge, lineWidth: 1))
        .overlay(
            shape.inset(by: 1)
                .strokeBorder(RibbonPalette.laneHighlight, lineWidth: 1)
                .allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: model.isCustomInstructionSelected)
    }

    private var ribbonWithFocusObservers: some View {
        ribbonSurface
        .onExitCommand { model.escape() }
        .onAppear { adopt(model.focusedCell) }
        .onChange(of: model.sessionSeq) { adopt(model.focusedCell) }
        .onChange(of: model.focusSeq) { adopt(model.focusedCell) }
        .onChange(of: model.focusedCell) { adopt(model.focusedCell) }
        .onChange(of: focus) {
            guard isLive else { return }
            guard model.focusedCell != .none else {
                focus = nil
                return
            }
            if let focus { model.focusedCell = focus }
        }
    }

    private var ribbonWithLayoutObservers: some View {
        ribbonWithFocusObservers
        .onChange(of: model.phase) {
            customRunHovered = false
            announcePhase()
            relayout()
            adopt(model.focusedCell)
        }
        .onChange(of: model.capturing) { relayout() }
        // The Direction field wraps to five lines, so what the user types is a
        // height input like any other.
        .onChange(of: model.instruction) { relayout() }
        .onChange(of: model.isCustomInstructionSelected) {
            hoveredAction = nil
            customRunHovered = false
            relayout()
        }
        .onChange(of: model.presetGroup) { hoveredAction = nil }
        .onChange(of: model.errorDetailsExpanded) { relayout() }
        .onChange(of: model.errorText) { relayout() }
        .onChange(of: model.retainedResultExpanded) { relayout() }
    }

    /// A lane flush against the top of the screen rounds only its bottom
    /// corners; one floating over the host or against the selection rounds all
    /// four.
    private var shape: UnevenRoundedRectangle {
        switch anchor {
        case .screen:
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: laneRadius,
                bottomTrailingRadius: laneRadius, topTrailingRadius: 0, style: .continuous)
        case .hostWindow, .belowSelection, .aboveSelection, .leftOfSelection, .rightOfSelection:
            UnevenRoundedRectangle(
                topLeadingRadius: laneRadius, bottomLeadingRadius: laneRadius,
                bottomTrailingRadius: laneRadius, topTrailingRadius: laneRadius,
                style: .continuous)
        }
    }

    /// The command row stays visible and readable while a request runs. Other
    /// actions go inert; the active action stays live as Cancel.
    private var locked: Bool { model.isLocked }

    private var showsCustomDrawer: Bool {
        model.isCustomInstructionSelected && model.phase != .scopeApproval
    }

    // MARK: - Command row

    /// The target and the set switch, a divider, then the five actions sharing
    /// what is left in equal measure — so a running label, a hover or a set
    /// switch never reflows the row.
    private var commandRow: some View {
        HStack(spacing: 2) {
            targetChip
            presetGroupChip
            Rectangle()
                .fill(RibbonPalette.divider)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 4)
            ForEach(model.actionDisplayOrder, id: \.self) { index in
                actionButton(at: index)
            }
        }
        .padding(inset)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    /// The target chip: always visible, and the one place the ribbon states
    /// what an action would actually act on. It reads "Reading…" — and
    /// refuses both the click and ⌘T — for the same brief window the capture
    /// makes `hasSelection` an optimistic guess, per `PanelModel.setScope`.
    ///
    /// While a request runs the chip is inert anyway, so it reports the
    /// coordinator's live stage instead whenever that says more than the
    /// active button already does — "Reading document" rather than a second
    /// "Improving".
    private var targetChip: some View {
        Button {
            model.toggleScope()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.scope == .document ? "doc.text" : "text.cursor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RibbonPalette.symbol)
                    .frame(width: 14)
                if let stage = liveStageNote {
                    Text(stage)
                        .foregroundStyle(RibbonPalette.text)
                } else {
                    Text(targetChipTitle)
                        .foregroundStyle(RibbonPalette.caption)
                    if let count = targetChipCount {
                        Text(count)
                            .monospacedDigit()
                            .foregroundStyle(RibbonPalette.text)
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 9)
            .frame(width: 156, height: controlHeight, alignment: .leading)
            .background(
                controlShape.fill(
                    targetHovered && model.targetChipEnabled
                        ? RibbonPalette.controlHover : .clear))
            .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        // Gated by hit testing rather than `.disabled`, which would also wash
        // out the label; `setScope` refuses a change while it is inert.
        .allowsHitTesting(model.targetChipEnabled)
        // Without a selection the chip is inert but still states the target,
        // so it stays at full strength; only a capture or a locked phase
        // dims it.
        .opacity(
            model.targetChipEnabled || liveStageNote != nil || !model.hasSelection ? 1 : 0.6)
        .focusable()
        .focused($focus, equals: .target)
        .ribbonFocusRing(model.focusedCell == .target, radius: controlRadius, inset: 0)
        .onHover { hovering in
            guard isLive else { return }
            targetHovered = hovering
        }
        .help(targetChipHelp)
        .accessibilityLabel("Target")
        .accessibilityValue(targetChipLabel)
        .accessibilityHint(targetChipHelp)
        .accessibilityIdentifier("Target")
    }

    /// The action-set switch: one chip naming the live set. A click — or the
    /// set shortcut, shown on hover like the actions' digits — moves to the
    /// next set, and the four preset buttons swap in place. Its width is
    /// reserved for the longest set name, so switching moves nothing.
    private var presetGroupChip: some View {
        let group = model.presetGroup
        let shortcut = model.presetGroupShortcutLabel
        return Button {
            model.cyclePresetGroup()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RibbonPalette.symbol)
                    .frame(width: 14)
                ZStack(alignment: .leading) {
                    ForEach(PresetGroup.all) { Text($0.title).hidden() }
                    Text(group.title).foregroundStyle(RibbonPalette.text)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: controlHeight)
            .background(
                controlShape.fill(
                    presetGroupHovered && !locked ? RibbonPalette.controlHover : .clear))
            .overlay(alignment: .topTrailing) {
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(RibbonPalette.caption)
                        .padding(.top, 3)
                        .padding(.trailing, 5)
                        .opacity(presetGroupHovered && !locked ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .focusable()
        .focused($focus, equals: .presetGroup)
        .ribbonFocusRing(model.focusedCell == .presetGroup, radius: controlRadius, inset: 0)
        .onHover { hovering in
            guard isLive else { return }
            presetGroupHovered = hovering
        }
        .help(presetGroupHelp)
        .accessibilityLabel("Action set")
        .accessibilityValue(group.title)
        .accessibilityHint(presetGroupHelp)
        .accessibilityIdentifier("PresetGroup")
    }

    private var presetGroupHelp: String {
        let next = model.presetGroup.next
        let action = "\(model.presetGroup.summary). Click for \(next.title)"
        guard let shortcut = model.presetGroupShortcutLabel else { return action + "." }
        return "\(action) (\(shortcut))."
    }

    private var targetChipTitle: String {
        if model.capturing { return "Reading…" }
        return model.scope == .document ? "Whole document" : "Selection"
    }

    private var targetChipCount: String? {
        guard !model.capturing, model.scope == .selection, model.selectionCharCount > 0
        else { return nil }
        return model.selectionCharCount.formatted()
    }

    private var targetChipLabel: String {
        [targetChipTitle, targetChipCount].compactMap { $0 }.joined(separator: " · ")
    }

    /// The coordinator's stage, when it is not just the active action's own
    /// progress label repeated.
    private var liveStageNote: String? {
        guard model.phase == .running, model.capturing || !model.runningTitle.isEmpty
        else { return nil }
        let stage = runningLabel
        let index = model.isCustomInstructionSelected
            ? PanelModel.customActionIndex
            : model.actionDisplayOrder.first { model.isActionSelected(at: $0) }
        guard let index, stage != model.actionProgressLabel(at: index) else { return nil }
        return stage
    }

    private var targetChipHelp: String {
        let scopeHelp = model.scope == .document
            ? "Targets the whole document. The entire document is sent to Copilot"
                + " after approval and may leave this Mac."
            : "Targets the current selection. Command T for the whole document."
        return model.targetAppName.isEmpty ? scopeHelp : "\(model.targetAppName). \(scopeHelp)"
    }

    // MARK: - Actions

    private func actionButton(at index: Int) -> some View {
        let title = model.actionTitle(at: index) ?? ""
        let symbol = model.actionSymbol(at: index) ?? ""
        let shortcut = model.actionShortcut(at: index) ?? ""
        let description = model.actionDescription(at: index)
        let isCustom = index == PanelModel.customActionIndex
        let selected = model.isActionSelected(at: index)
        // Custom's own progress runs on the drawer's Run control, beside the
        // words it was asked to apply; its row button simply stays lit.
        let processing = model.phase == .running && selected && !isCustom
        let highlighted = model.isActionHighlighted(at: index)
        let status = (model.actionProgressLabel(at: index) ?? title) + "…"
        let isHovered = hoveredAction == index
        let displayedSymbol = processing && isHovered ? "xmark" : symbol
        let unavailable = model.isLocked && !processing
        let showShortcut = isHovered && !processing && !unavailable
        let ink = highlighted ? RibbonPalette.onAccent : RibbonPalette.text
        return Button {
            if processing {
                model.onCancelRun?()
            } else {
                model.activateAction(at: index)
            }
        } label: {
            ZStack {
                // Every label this slot can show in any set or phase, so
                // switching sets or starting a run never moves a button. The
                // visible icon and label are centered over it as one group,
                // so the gap between them is the same in every slot.
                HStack(spacing: 6) {
                    Color.clear.frame(width: 14, height: 1)
                    ZStack {
                        ForEach(model.actionLabelCandidates(at: index), id: \.self) { label in
                            Text(label + "…")
                        }
                    }
                }
                .hidden()
                HStack(spacing: 6) {
                    Image(systemName: displayedSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(highlighted ? RibbonPalette.onAccent : RibbonPalette.symbol)
                        .frame(width: 14)
                    Text(processing ? (isHovered ? "Cancel" : status) : title)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight)
            .background(
                controlShape.fill(
                    highlighted
                        ? RibbonPalette.accent
                        : isHovered && !unavailable ? RibbonPalette.controlHover : .clear))
            .overlay(alignment: .topTrailing) {
                Text(shortcut)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(highlighted ? RibbonPalette.onAccent : RibbonPalette.caption)
                    .padding(.top, 3)
                    .padding(.trailing, 5)
                    .opacity(showShortcut ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .overlay {
                if processing {
                    SwooshBorder(
                        shape: controlShape,
                        tint: swooshColor,
                        animated: !reduceMotion,
                        lineWidth: 1.5)
                }
            }
            .contentShape(controlShape)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: .action(index))
        // The swoosh already marks the running action; a ring would cover it.
        // On a lit action the ring stands just outside the vermilion rather
        // than on it.
        .ribbonFocusRing(
            model.focusedCell == .action(index) && !processing,
            radius: highlighted ? controlRadius + 3 : controlRadius,
            inset: highlighted ? -3 : 0)
        // A lit Custom stays at full strength while its own run is in flight;
        // `activateAction` already refuses it while the ribbon is locked.
        .disabled(unavailable && !highlighted)
        .opacity(unavailable && !highlighted ? 0.4 : 1)
        .help(
            processing
                ? "\(model.runningStatus(at: index)). Click to cancel."
                : [title + " (\(shortcut))", description].compactMap { $0 }.joined(separator: " — ")
        )
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
        .accessibilityLabel(processing ? model.runningStatus(at: index) : title)
        .accessibilityValue(processing ? "In progress" : selected ? "Selected" : "Not selected")
        .accessibilityHint(processing
            ? "Click to cancel."
            : isCustom
                ? "\(index + 1) when not typing. Opens the custom instruction field."
                : "\(index + 1) when not typing. Runs immediately.")
        .accessibilityIdentifier("Action-\(index + 1)")
    }

    // MARK: - Custom drawer

    /// The instruction field and its Run control, opened under the row rather
    /// than in place of the Custom button. The field takes the lane's full
    /// width, wraps to five lines and then scrolls.
    private var customDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            directionField
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                customRunControl
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(controlShape.fill(RibbonPalette.field))
        .overlay(controlShape.strokeBorder(RibbonPalette.fieldEdge, lineWidth: 1))
        .ribbonFocusRing(model.focusedCell == .direction, radius: controlRadius, inset: 0)
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
    }

    private var directionField: some View {
        TextField("", text: $model.instruction, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .font(directionFont)
            .foregroundStyle(RibbonPalette.text)
            .tint(RibbonPalette.accent)
            .focused($focus, equals: .direction)
            .onSubmit { model.runPrimary() }
            .overlay(alignment: .topLeading) { placeholder }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(locked)
            .accessibilityLabel("Direction")
            .accessibilityIdentifier("CustomInstruction")
    }

    private var customRunControl: some View {
        let processing = model.phase == .running
        let title = processing ? (customRunHovered ? "Cancel" : "Working") : model.customSubmitTitle
        let symbol = processing ? (customRunHovered ? "xmark" : "sparkles") : "return"
        let enabled = processing || (!model.isLocked && model.canRunPrimary)
        let runShape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button {
            if processing {
                model.onCancelRun?()
            } else {
                model.runPrimary()
            }
        } label: {
            ZStack {
                // Reserve the widest state so Run → Working → Cancel never
                // changes the button's width.
                ForEach(["Run", "Working", "Cancel"], id: \.self) { label in
                    HStack(spacing: 6) {
                        Text(label)
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                    }
                    .hidden()
                }
                HStack(spacing: 6) {
                    Text(title)
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(
                processing ? RibbonPalette.text
                    : enabled ? RibbonPalette.onAccent : RibbonPalette.caption)
            .padding(.horizontal, 12)
            .frame(minWidth: 84, minHeight: 28)
            .background(
                runShape.fill(
                    processing
                        ? (customRunHovered ? RibbonPalette.controlHover : RibbonPalette.lane)
                        : enabled ? RibbonPalette.accent : RibbonPalette.controlHover))
            .overlay {
                if processing {
                    SwooshBorder(
                        shape: runShape,
                        tint: swooshColor,
                        animated: !reduceMotion,
                        lineWidth: 1.5)
                }
            }
            .contentShape(runShape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .focusable()
        .focused($focus, equals: .run)
        .ribbonFocusRing(model.focusedCell == .run && !processing, radius: 10, inset: -3)
        .help(processing ? "Cancel custom action" : "Run custom action")
        .onHover { isHovering in
            guard isLive else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                customRunHovered = processing && isHovering
            }
        }
        .accessibilityLabel(processing ? "Cancel custom action" : title)
        .accessibilityIdentifier("Run")
    }

    /// Unfolds downward from the row, the way the lane itself grows.
    private var drawerTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private var directionFont: Font { .system(size: 13.5) }

    // MARK: - Control chrome

    /// One radius for every control on the lane.
    private var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
    }

    /// The field's own prompt, drawn rather than handed to `TextField`.
    ///
    /// SwiftUI resolves a `prompt`'s colour from the system placeholder
    /// register and ignores any foreground style put on the `Text`, which
    /// would leave the colour to the system appearance rather than to the
    /// lane's fixed register. Drawing it makes the colour ours.
    @ViewBuilder
    private var placeholder: some View {
        if model.instruction.isEmpty {
            Text("Describe the change…")
                .font(directionFont)
                .foregroundStyle(RibbonPalette.caption)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Status strip

extension RibbonView {
    /// The phases that still earn a row of their own below the command row.
    ///
    /// Working lives on the active action control, so `.running` needs
    /// nothing here. Every other terminal phase carries something the command
    /// row has no room for: a failure's provider message and three recoveries,
    /// an applied edit's one honest Undo, or a retained result's reason and
    /// its own copy — and each is the one moment that phase wants the user's
    /// attention.
    @ViewBuilder
    fileprivate var statusStrip: some View {
        switch model.phase {
        case .error:
            VStack(alignment: .leading, spacing: 0) {
                strip {
                    statusLabel(errorLabel, dot: RibbonPalette.error, tint: RibbonPalette.errorText)
                    Spacer(minLength: 8)
                    GhostButton(
                        model.errorDetailsExpanded ? "Hide details" : "Details",
                        tint: RibbonPalette.caption
                    ) {
                        model.errorDetailsExpanded.toggle()
                    }
                    .focusable()
                    .focused($focus, equals: .errorDetails)
                    .ribbonFocusRing(model.focusedCell == .errorDetails, radius: 8, inset: -2)
                    .accessibilityIdentifier("ErrorDetails")
                    GhostButton("Copy", tint: RibbonPalette.caption) { copyError() }
                        .focusable()
                        .focused($focus, equals: .errorCopy)
                        .ribbonFocusRing(model.focusedCell == .errorCopy, radius: 8, inset: -2)
                        .accessibilityIdentifier("CopyError")
                    GhostButton("Retry", tint: RibbonPalette.text) { model.onRetry?() }
                        .focusable()
                        .focused($focus, equals: .errorRetry)
                        .ribbonFocusRing(model.focusedCell == .errorRetry, radius: 8, inset: -2)
                        .accessibilityIdentifier("Retry")
                }
                if model.errorDetailsExpanded {
                    errorDetails
                }
            }
        case .applied:
            strip {
                statusLabel(appliedLabel, dot: RibbonPalette.applied, tint: RibbonPalette.appliedText)
                Spacer(minLength: 8)
                if model.undoAvailable {
                    GhostButton("Undo", tint: RibbonPalette.text) {
                        _ = model.undoLastVersion()
                    }
                    .focusable()
                    .focused($focus, equals: .appliedUndo)
                    .ribbonFocusRing(model.focusedCell == .appliedUndo, radius: 8, inset: -2)
                    .accessibilityIdentifier("UndoApplied")
                }
            }
        case .retained:
            VStack(alignment: .leading, spacing: 0) {
                strip {
                    statusLabel(retainedLabel, dot: RibbonPalette.caption)
                    Spacer(minLength: 8)
                    if !model.retainedResult.isEmpty {
                        GhostButton(
                            model.retainedResultExpanded ? "Hide result" : "Show result",
                            tint: RibbonPalette.caption
                        ) {
                            model.retainedResultExpanded.toggle()
                        }
                        .focusable()
                        .focused($focus, equals: .retainedDisclosure)
                        .ribbonFocusRing(
                            model.focusedCell == .retainedDisclosure, radius: 8, inset: -2)
                        .accessibilityIdentifier("RetainedDisclosure")
                    }
                    // Explicit only: a retained result is never retried on its
                    // own, and Copy is the one recovery this row offers.
                    if !model.retainedResult.isEmpty {
                        GhostButton("Copy result", tint: RibbonPalette.text) {
                            model.onCopyRetainedResult?()
                        }
                        .focusable()
                        .focused($focus, equals: .retainedCopy)
                        .ribbonFocusRing(model.focusedCell == .retainedCopy, radius: 8, inset: -2)
                        .accessibilityIdentifier("CopyRetained")
                    }
                }
                Text(model.retainedReason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RibbonPalette.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                if model.retainedResultExpanded, !model.retainedResult.isEmpty {
                    retainedResultDisclosure
                }
            }
        case .idle, .scopeApproval, .running:
            EmptyView()
        }
    }

    private func strip(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            hairline
            HStack(spacing: 8) {
                content()
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 36)
        }
    }

    private func statusLabel(
        _ text: String, dot: Color, tint: Color = RibbonPalette.caption
    ) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    fileprivate var hairline: some View {
        Rectangle().fill(RibbonPalette.divider).frame(height: 1)
    }

    /// The verb shown while a request runs. Stays honest during the brief
    /// background-capture window before the provider call begins, and — once
    /// it starts — prefers the coordinator's live stage over a fixed verb, so
    /// a whole-document generation's capture step is never announced as
    /// whatever the selected preset happens to be named.
    private var runningLabel: String {
        if model.capturing { return "Reading selection" }
        if !model.runningTitle.isEmpty { return model.runningTitle }
        return model.resolvedActionTitle
    }

    private var errorLabel: String {
        model.errorText.isEmpty ? "Provider failed" : model.errorText
    }

    private var appliedLabel: String {
        if let status = model.appliedStatusText, !status.isEmpty { return status }
        return model.appliedActionName.isEmpty
            ? "Applied"
            : "\(model.appliedActionName) applied"
    }

    private var retainedLabel: String {
        model.retainedResult.isEmpty ? "No result to apply" : "Result ready, not applied"
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

    /// A retained result's own bounded disclosure, mirroring the review
    /// gate's and the error strip's: five lines before it scrolls, so a long
    /// generated result never turns the status strip into the window it is
    /// standing in for.
    private var retainedResultDisclosure: some View {
        ScrollView {
            Text(model.retainedResult)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(RibbonPalette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 5 * 15)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityLabel("Retained result")
    }

    /// A deliberate copy, so it goes straight to the pasteboard. Routing it
    /// through `SelectionCapture`'s snapshot/restore machinery would be wrong:
    /// that exists to protect the user's clipboard *during* an edit cycle.
    private func copyError() {
        model.copyErrorToPasteboard()
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
        case .scopeApproval:
            let action = model.pendingScopeApprovalActionTitle
            let question = action.isEmpty ? "Send the whole document?" : "\(action) the whole document?"
            return "\(question) The entire document may leave this Mac."
        case .running: return "\(runningLabel)"
        case .applied: return appliedLabel
        case .retained: return retainedLabel
        case .error: return errorLabel
        }
    }

    fileprivate func relayout() {
        guard isLive else { return }
        onLayoutChange()
    }

    // MARK: - Focus

    /// Take the model's focus and hand it to SwiftUI, one turn later.
    ///
    /// Deferred because the cell may still be disabled in the update that
    /// changed the phase; SwiftUI drops focus on a disabled control, so
    /// claiming it in the same turn would be undone immediately.
    fileprivate func adopt(_ cell: PanelModel.Cell) {
        guard isLive else { return }
        Task { @MainActor in
            guard model.focusedCell == cell else { return }
            focus = cell == .none ? nil : cell
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
