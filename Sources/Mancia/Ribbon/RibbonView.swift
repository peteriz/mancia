import AppKit
import SwiftUI

/// The command ribbon — a slim lane that opens against the text being edited:
/// just under the selection, or just over it when the selection sits too near
/// the foot of its window. With no selection to sit against, or no room beside
/// one, it falls back to a predictable resting place at the top — under the
/// menu bar, or under the frontmost window's title bar. See `RibbonPlacement`.
///
/// The lane reads left to right as one sentence: **Target · Action · Direction
/// · Run**, on a single row. The cells carry no captions: they were the first
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
    /// the Direction field and refuses it to the three `.focusable()` cells, so
    /// Tab left the ring stuck on the field while the model — and therefore
    /// Return, which the window routes by `focusedCell` — had already moved on.
    /// The ring reads the model, which is the stop the keyboard is actually on.
    @FocusState private var focus: PanelModel.Cell?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The height of every control on the command row, and so the height the
    /// row rests at once its padding is added.
    private let controlHeight: CGFloat = 32
    /// The command row's resting height. It grows when the Direction field
    /// wraps, and everything below it — the failure strip, the review
    /// region — is added by later phases and grows the lane further downward.
    private let rowHeight: CGFloat = 48
    /// Room for the widest thing each menu can say — "Selection · 12345" and
    /// "Your instruction" — so neither cell resizes as its value changes and
    /// drags the rest of the row sideways.
    private let targetMinWidth: CGFloat = 132
    private let actionMinWidth: CGFloat = 158

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
        // The Direction field wraps to four lines, so what the user types is a
        // height input like any other.
        .onChange(of: model.instruction) { relayout() }
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
        case .hostWindow, .belowSelection, .aboveSelection:
            UnevenRoundedRectangle(
                topLeadingRadius: 12, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
        }
    }

    /// The command row stays visible and readable while a request runs — the
    /// user can check what they asked for — but its controls go inert.
    private var locked: Bool { model.phase == .running || model.phase == .confirm }

    // MARK: - Command row

    /// One line, read left to right: **Target · Action · Direction**, then the
    /// trailing cluster — iteration history, live status, Run.
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
                actionCell
                directionCell
            }
            .opacity(locked ? 0.5 : 1)
            .disabled(locked)

            // The field stops at its cap and this takes the rest. The slack is
            // what the version counter and the status word grow into when a run
            // starts, so the field gives up far less width than it otherwise
            // would — and what the user typed is much less likely to rewrap
            // underneath them.
            Spacer(minLength: 0)

            trailingCluster
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: rowHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
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
                    model.returnFocusToDirection()
                }
                Button("Entire document") {
                    model.setScope(.document)
                    model.returnFocusToDirection()
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

    /// ⌘1…⌘4, and nothing past the fourth preset — a catalog longer than that
    /// has outgrown a digit row, and an unlabeled fifth key is worse than none.
    /// `\0` is `KeyEquivalent`'s way of asking for no shortcut at all.
    private func presetShortcut(_ index: Int) -> KeyEquivalent {
        index < 4 ? KeyEquivalent(Character("\(index + 1)")) : KeyEquivalent("\0")
    }

    /// The action that will actually run, spelled out. The menu pins a preset
    /// explicitly; `Your instruction` unpins and hands the decision back to the
    /// Direction field.
    private var actionCell: some View {
        Menu {
            ForEach(Array(PanelPreset.all.enumerated()), id: \.element.id) { index, preset in
                Button {
                    model.selectPreset(at: index)
                } label: {
                    Label(preset.title, systemImage: preset.action.symbol)
                }
                // Renders the ⌘-digit beside the item. Only the first four get
                // one, and it is a hint rather than a binding: `KeyablePanel`
                // resolves these above the SwiftUI tree and consumes them, so
                // the key works whether or not this menu has ever been opened.
                .keyboardShortcut(presetShortcut(index), modifiers: .command)
            }
            Divider()
            Button("Your instruction") { model.clearPreset() }
                .keyboardShortcut("0", modifiers: .command)
        } label: {
            chipLabel(
                model.resolvedActionSymbol, model.resolvedActionTitle,
                minWidth: actionMinWidth)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(controlShape.fill(RibbonPalette.control))
        .focusable()
        .focused($focus, equals: .action)
        .ribbonFocusRing(model.focusedCell == .action, radius: 8, inset: 0)
        .accessibilityLabel("Action")
        .accessibilityValue(model.resolvedActionTitle)
        .accessibilityIdentifier("Action")
    }

    /// The instruction field. Optional by design — an empty Direction is a
    /// valid Improve, which is what the Action chip is there to say out loud.
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

    private var directionFont: Font { .system(size: 13, weight: .medium) }

    // MARK: - Trailing cluster

    /// Iteration history, live status and Run, in that order.
    ///
    /// Status used to own a 34pt strip of its own: a dot, one word, and the
    /// rest of the lane empty. Both it and the version counter now ride beside
    /// the control they are about, in the width the Direction field gave back.
    /// Only a failure still earns a row — it carries a message too long for
    /// this cluster and three recoveries to offer.
    private var trailingCluster: some View {
        HStack(spacing: 10) {
            secondaryAction
            inlineStatus
            runControl
        }
        .frame(height: controlHeight)
    }

    /// The slot the version counter and Cancel share. They never co-occur: one
    /// belongs to a finished run, the other to a running one.
    @ViewBuilder
    private var secondaryAction: some View {
        switch model.phase {
        case .running:
            GhostButton("Cancel", tint: RibbonPalette.caption) { model.onCancelRun?() }
                .accessibilityIdentifier("Cancel")
        case .applied where model.versionCount > 1:
            VersionNav(
                model: model, tint: RibbonPalette.caption,
                faint: RibbonPalette.caption.opacity(0.45))
        default:
            EmptyView()
        }
    }

    /// A resting lane reports nothing: the command row already says everything
    /// there is to know. While capturing, the Target chip carries the word.
    @ViewBuilder
    private var inlineStatus: some View {
        switch model.phase {
        case .running:
            statusLabel("\(runningLabel)…", dot: RibbonPalette.caption)
        case .applied:
            statusLabel("Improved", dot: RibbonPalette.applied, tint: RibbonPalette.applied)
        default:
            EmptyView()
        }
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
        Button { model.runPrimary() } label: {
            // Hidden, not absent: the button still takes its size from the
            // real label, so the two cannot drift apart. What is drawn is the
            // overlay below.
            runLabel
                .hidden()
                .frame(minWidth: 72, minHeight: controlHeight)
        }
        .buttonStyle(.plain)
        // The fill and the running border hang off the button rather than off
        // its label: a `Text` wrapped in a background is rendered as an image,
        // and an image-backed button has no accessible name to override.
        .background(controlShape.fill(locked ? RibbonPalette.actionInert : RibbonPalette.action))
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
        .disabled(locked)
        // Drawn *after* `disabled`, and so outside the subtree it dims.
        // SwiftUI fades a disabled button's label whatever style it wears, and
        // that fade is the collapse described above; the softened fill is the
        // signal instead. `disabled` still owns the behaviour — no hit
        // testing, out of the focus chain, dimmed to VoiceOver.
        .overlay { runLabel.allowsHitTesting(false) }
        .help(model.resolvedActionTitle)
        // The visible glyph is a keyboard hint, not a word.
        .accessibilityLabel("Run")
        .accessibilityValue(model.resolvedActionTitle)
        .accessibilityIdentifier("Run")
    }

    private var runLabel: some View {
        Text("Run ↵")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RibbonPalette.onAction)
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
    /// Every other status — reading, working, done — is a dot and a word, and
    /// those now ride in the command row beside the control they describe. A
    /// failure cannot: it carries a provider message too long for that cluster
    /// and three recoveries to offer, and it is the one state where taking the
    /// user's attention is the point.
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
