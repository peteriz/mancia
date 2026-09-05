import SwiftUI

/// The review gate: what opens under the command row when a finished edit would
/// replace the whole document.
///
/// The panel this replaces spent one line on the decision — a character delta
/// sharing a row with its own buttons. A whole-document overwrite is the app's
/// highest blast-radius action, so here the question leads, the size change is
/// spelled out rather than abbreviated, and the result itself is one disclosure
/// away.
///
/// The disclosure shows the result alone until the coordinator populates
/// `pendingOriginalPreview`, at which point it becomes a genuine bounded
/// side-by-side of the document as it stands against the document as it would
/// read — still no line-level diff engine, which for a whole-document swap
/// would need to hold two full copies to align, but a real comparison rather
/// than a size delta alone.
struct RibbonReviewView: View {
    @Bindable var model: PanelModel
    var focus: FocusState<PanelModel.Cell?>.Binding

    /// Tall enough to read a paragraph or two, short enough that the lane never
    /// becomes the window it is trying not to be.
    private let previewMaxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Replace entire document?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RibbonPalette.text)
                Text(
                    ApplyConfirmation.detailedSummary(
                        originalCharacters: model.pendingOriginalCharCount,
                        resultCharacters: model.pendingResultCharCount)
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(RibbonPalette.caption)
            }

            disclosure

            if model.previewExpanded {
                preview
            }

            // The buttons stay pinned to the trailing edge whether or not the
            // preview is open, so expanding it never moves the thing the user
            // is reaching for.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                GhostButton("Keep editing", tint: RibbonPalette.caption) {
                    model.onDeclinePending?()
                }
                .focusable()
                .focused(focus, equals: .reviewDecline)
                .ribbonFocusRing(model.focusedCell == .reviewDecline, radius: 8, inset: -2)
                .accessibilityIdentifier("KeepEditing")
                AccentButton(
                    "Replace", fill: RibbonPalette.action, foreground: RibbonPalette.onAction
                ) {
                    model.onConfirmApply?()
                }
                .focusable()
                .focused(focus, equals: .reviewApprove)
                .ribbonFocusRing(model.focusedCell == .reviewApprove, radius: 8, inset: -2)
                .accessibilityLabel("Replace document")
                .accessibilityIdentifier("ReplaceDocument")
            }
            .frame(height: 30)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosure: some View {
        Button {
            model.previewExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(disclosureTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(model.previewExpanded ? 180 : 0))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(RibbonPalette.caption)
            .frame(minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focus, equals: .reviewDisclosure)
        .ribbonFocusRing(model.focusedCell == .reviewDisclosure, radius: 6, inset: -2)
        .accessibilityLabel(disclosureTitle)
        .accessibilityIdentifier("ShowResult")
    }

    private var disclosureTitle: String {
        if model.previewExpanded { return "Hide result" }
        return model.pendingOriginalPreview.isEmpty ? "Show result" : "Compare changes"
    }

    /// The result, alone when there is nothing to compare it against, or
    /// beside the text it would replace once the coordinator has populated
    /// `pendingOriginalPreview` — a genuine side-by-side comparison bounded to
    /// the same height either way, rather than a diff view that could grow to
    /// the size of the document itself.
    @ViewBuilder
    private var preview: some View {
        if model.pendingOriginalPreview.isEmpty {
            column(title: "Proposed", text: model.pendingResultPreview, label: "Proposed result")
        } else {
            HStack(alignment: .top, spacing: 8) {
                column(
                    title: "Original", text: model.pendingOriginalPreview,
                    label: "Original document")
                column(
                    title: "Proposed", text: model.pendingResultPreview, label: "Proposed result")
            }
        }
    }

    /// Monospaced on purpose, and the one place in the app where it isn't
    /// costume: this is a verbatim result being inspected character for
    /// character against a character count.
    private func column(title: String, text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(RibbonPalette.caption)
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RibbonPalette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: previewMaxHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RibbonPalette.directionTint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(RibbonPalette.laneEdge, lineWidth: 1)
            )
            .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
