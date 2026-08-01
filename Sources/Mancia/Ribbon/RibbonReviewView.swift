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
/// v1 deliberately does not diff. The size delta plus the full result is enough
/// to make the decision safely, and a real diff is a self-contained follow-up.
struct RibbonReviewView: View {
    @Bindable var model: PanelModel

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
                    model.onCancelRun?()
                }
                .accessibilityIdentifier("KeepEditing")
                AccentButton(
                    "Replace ↵", fill: RibbonPalette.action, foreground: RibbonPalette.onAction
                ) {
                    model.onConfirmApply?()
                }
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
                Text(model.previewExpanded ? "Hide result" : "Show result")
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
        .accessibilityLabel(model.previewExpanded ? "Hide result" : "Show result")
        .accessibilityIdentifier("ShowResult")
    }

    /// Monospaced on purpose, and the one place in the app where it isn't
    /// costume: this is a verbatim result being inspected character for
    /// character against a character count.
    private var preview: some View {
        ScrollView {
            Text(model.pendingResultPreview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RibbonPalette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: previewMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RibbonPalette.text.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RibbonPalette.laneEdge, lineWidth: 1)
        )
        .accessibilityLabel("Proposed result")
    }
}
