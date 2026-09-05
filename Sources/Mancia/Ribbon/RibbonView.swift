import AppKit
import SwiftUI

/// The command ribbon — a slim lane that opens against the text being edited:
/// just under the selection, or just over it when the selection sits too near
/// the foot of its window. With no selection to sit against, or no room beside
/// one, it falls back to a predictable resting place at the top — under the
/// menu bar, or under the frontmost window's title bar. See `RibbonPlacement`.
///
/// The lane is one compact strip of actions.
/// All five actions are visible; selecting Custom replaces it with Direction
/// while the four built-in actions stay put. The cells carry no captions: they
/// were the first thing to go when the row was collapsed to one line, and the
/// resolved action is spelled out in the Action chip itself instead — which is
/// what the panel
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
    @State private var customRunHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The height of every control on the command row, and so the height the
    /// row rests at once its padding is added.
    private let controlHeight: CGFloat = 32
    /// The command row's resting height. It grows when the Direction field
    /// wraps, and everything below it — the failure strip, the review
    /// region — is added by later phases and grows the lane further downward.
    private let rowHeight: CGFloat = 48

    var body: some View {
        ribbonWithLayoutObservers
    }

    private var ribbonSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            targetRow
            commandRow
            statusStrip
            if model.phase == .scopeApproval {
                hairline
                RibbonScopeApprovalView(model: model, focus: $focus)
            }
            if model.phase == .confirm {
                hairline
                RibbonReviewView(model: model, focus: $focus)
            }
        }
        .frame(width: width)
        .background {
            glassSurface(tint: RibbonPalette.laneTint, in: shape)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(RibbonPalette.laneEdge, lineWidth: 1))
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
        // The Direction field wraps to four lines, so what the user types is a
        // height input like any other.
        .onChange(of: model.instruction) { relayout() }
        .onChange(of: model.isCustomInstructionSelected) {
            hoveredAction = nil
            customRunHovered = false
            relayout()
        }
        .onChange(of: model.previewExpanded) { relayout() }
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
                topLeadingRadius: 0, bottomLeadingRadius: 20,
                bottomTrailingRadius: 20, topTrailingRadius: 0, style: .continuous)
        case .hostWindow, .belowSelection, .aboveSelection, .leftOfSelection, .rightOfSelection:
            UnevenRoundedRectangle(
                topLeadingRadius: 20, bottomLeadingRadius: 20,
                bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
        }
    }

    /// The command row stays visible and readable while a request runs. Other
    /// actions go inert; the active action stays live as Cancel.
    private var locked: Bool { model.isLocked }

    // MARK: - Target row

    /// A thin strip of its own, above the command row: the target chip needs
    /// height, not a share of the command row's width. That row is already
    /// tight — five buttons centered with only a few points of slack on
    /// either side at the lane's standard width — so overlaying the chip
    /// there collided with Action-1's own hit target. A row of its own costs
    /// height, which the lane already resizes to per phase, rather than width,
    /// which `RibbonPlacement` has already budgeted down to the point.
    private var targetRow: some View {
        HStack(spacing: 0) {
            targetChip
            Spacer(minLength: 0)
            if model.phase == .running {
                Text(runningLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RibbonPalette.caption)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The target chip: always visible, and the one place the ribbon states
    /// what an action would actually act on. It reads "Reading…" — and
    /// refuses both the click and ⌘T — for the same brief window the capture
    /// makes `hasSelection` an optimistic guess, per `PanelModel.setScope`.
    private var targetChip: some View {
        Button {
            model.toggleScope()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.scope == .document ? "doc.text" : "text.cursor")
                    .font(.system(size: 10, weight: .semibold))
                Text(targetChipLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(RibbonPalette.caption)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Capsule(style: .continuous).fill(RibbonPalette.controlTint))
        .overlay(Capsule(style: .continuous).strokeBorder(RibbonPalette.controlEdge, lineWidth: 1))
        .disabled(!model.targetChipEnabled)
        .opacity(model.targetChipEnabled ? 1 : 0.5)
        .focusable()
        .focused($focus, equals: .target)
        .ribbonFocusRing(model.focusedCell == .target, radius: 8, inset: -2)
        .help(targetChipHelp)
        .accessibilityLabel("Target")
        .accessibilityValue(targetChipLabel)
        .accessibilityHint(targetChipHelp)
        .accessibilityIdentifier("Target")
    }

    private var targetChipLabel: String {
        if model.capturing { return "Reading…" }
        switch model.scope {
        case .selection:
            return model.selectionCharCount > 0
                ? "Selection · \(model.selectionCharCount)" : "Selection"
        case .document:
            return "Whole document"
        }
    }

    private var targetChipHelp: String {
        let scopeHelp = model.scope == .document
            ? "Targets the whole document. The entire document is sent to Copilot"
                + " after approval and may leave this Mac."
            : "Targets the current selection. Command T for the whole document."
        return model.targetAppName.isEmpty ? scopeHelp : "\(model.targetAppName). \(scopeHelp)"
    }

    // MARK: - Command row

    /// One line of five Actions. Direction and its inline Run control replace
    /// Custom while it is selected.
    ///
    /// Each cell used to carry a caption above its value. They were the widest
    /// thing on the lane and said the least: "Selection · 22", "Improve" and a
    /// prompted field all name themselves, so the captions only repeated the
    /// answer in smaller type. Dropping them collapsed the row from two lines
    /// to one and let every control size to its own content instead of to a
    /// fixed width chosen to fit a label.
    private var commandRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            actionStrip
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(minHeight: rowHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: model.isCustomInstructionSelected)
    }

    // MARK: - Cells

    /// The four built-ins keep fixed positions. Direction replaces Custom's
    /// trailing slot and absorbs the room added by the expanded ribbon.
    private var actionStrip: some View {
        HStack(spacing: 8) {
            ForEach(model.actionDisplayOrder, id: \.self) { index in
                if index == PanelModel.customActionIndex,
                   model.isCustomInstructionSelected
                {
                    directionCell
                        .transition(directionTransition)
                } else {
                    actionButton(at: index)
                }
            }
        }
    }

    private func actionButton(at index: Int) -> some View {
        let title = model.actionTitle(at: index) ?? ""
        let symbol = model.actionSymbol(at: index) ?? ""
        let shortcut = model.actionShortcut(at: index) ?? ""
        let description = model.actionDescription(at: index)
        let selected = model.isActionSelected(at: index)
        let processing = model.phase == .running && selected
        let status = model.actionProgressLabel(at: index) ?? title
        let isHovered = hoveredAction == index
        let displayedSymbol = processing && isHovered ? "xmark" : symbol
        let unavailable = model.isLocked && !processing
        let showShortcut = isHovered && !processing && !unavailable
        return Button {
            if processing {
                model.onCancelRun?()
            } else {
                model.activateAction(at: index)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: displayedSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RibbonPalette.symbol)
                    .frame(width: 14)
                ZStack {
                    Text(title).opacity(!processing && !showShortcut ? 1 : 0)
                    Text(shortcut).opacity(showShortcut ? 1 : 0)
                    Text(status).opacity(processing && !isHovered ? 1 : 0)
                    Text("Cancel").opacity(processing && isHovered ? 1 : 0)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RibbonPalette.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background(
            controlShape.fill(
                isHovered
                    ? RibbonPalette.controlHoverTint
                    : RibbonPalette.controlTint))
        .overlay {
            if processing {
                SwooshBorder(
                    shape: controlShape,
                    tint: swooshColor,
                    animated: !reduceMotion,
                    lineWidth: 2)
            } else {
                controlShape.strokeBorder(RibbonPalette.controlEdge, lineWidth: 1)
            }
        }
        .focusable()
        .focused($focus, equals: .action(index))
        .ribbonFocusRing(model.focusedCell == .action(index), radius: 8, inset: 0)
        .disabled(unavailable)
        .opacity(unavailable ? 0.5 : 1)
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
            : index == PanelModel.customActionIndex
                ? "\(index + 1) when not typing. Opens the custom instruction field."
                : "\(index + 1) when not typing. Runs immediately.")
        .accessibilityIdentifier("Action-\(index + 1)")
    }

    /// Let SwiftUI allocate the room left by the fixed-width preset buttons.
    private var directionCell: some View {
        HStack(alignment: .top, spacing: 8) {
            directionField
            customRunControl
        }
        .frame(maxWidth: .infinity, minHeight: controlHeight, alignment: .topLeading)
    }

    private var directionField: some View {
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
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: controlHeight, alignment: .topLeading)
            .disabled(locked)
            .background(controlShape.fill(RibbonPalette.directionTint))
            // Past four lines the field scrolls, and without this the line
            // sliding out of view draws over the field's own top edge.
            .clipShape(controlShape)
            .overlay(controlShape.strokeBorder(RibbonPalette.controlEdge, lineWidth: 1))
            .ribbonFocusRing(model.focusedCell == .direction, radius: 8, inset: 0)
            .accessibilityLabel("Direction")
            .accessibilityIdentifier("CustomInstruction")
    }

    private var customRunControl: some View {
        let processing = model.phase == .running
        let title = processing ? (customRunHovered ? "Cancel" : "Working") : model.customSubmitTitle
        let symbol = processing ? (customRunHovered ? "xmark" : "sparkles") : "play.fill"
        return Button {
            if processing {
                model.onCancelRun?()
            } else {
                model.runPrimary()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(processing ? RibbonPalette.text : RibbonPalette.onCustomRun)
            .frame(width: 96)
            .frame(minHeight: controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            controlShape.fill(
                processing
                    ? (customRunHovered
                        ? RibbonPalette.controlHoverTint
                        : RibbonPalette.controlTint)
                    : RibbonPalette.customRun))
        .overlay {
            if processing {
                SwooshBorder(
                    shape: controlShape,
                    tint: swooshColor,
                    animated: !reduceMotion,
                    lineWidth: 2)
            }
        }
        .disabled((model.isLocked && !processing) || (!processing && !model.canRunPrimary))
        .focusable()
        .focused($focus, equals: .run)
        .ribbonFocusRing(
            model.focusedCell == .run, radius: 8, inset: 0,
            tint: processing ? RibbonPalette.caption : RibbonPalette.onCustomRun)
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

    private var directionTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .modifier(
            active: HorizontalReveal(progress: 0),
            identity: HorizontalReveal(progress: 1))
    }

    private var directionFont: Font { .system(size: 13, weight: .medium) }

    // MARK: - Control chrome

    /// A frosted surface rather than a liquid one.
    ///
    /// Native Liquid Glass is nearly clear, so over a white document the lane
    /// and its controls vanished into the page. A material base carries the
    /// blur, and the neutral tint above it holds a fixed step of contrast whatever
    /// is behind the ribbon. Reduce Transparency drops to an opaque surface.
    @ViewBuilder
    private func glassSurface<S: Shape>(
        tint: Color,
        in shape: S
    ) -> some View {
        if reduceTransparency {
            shape.fill(RibbonPalette.laneOpaque)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(tint))
        }
    }

    /// One radius for every control on the lane.
    private var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            Text("Describe the change…")
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
                    statusLabel(errorLabel, dot: RibbonPalette.error, tint: RibbonPalette.error)
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
                    GhostButton("Retry", tint: RibbonPalette.error) { model.onRetry?() }
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
                statusLabel(appliedLabel, dot: RibbonPalette.applied, tint: RibbonPalette.applied)
                Spacer(minLength: 8)
                if model.undoAvailable {
                    GhostButton("Undo", tint: RibbonPalette.caption) {
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
                        GhostButton("Copy result", tint: RibbonPalette.caption) {
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
        case .idle, .scopeApproval, .running, .confirm:
            EmptyView()
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
        case .confirm: return "Replace entire document?"
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
