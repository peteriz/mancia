import SwiftUI

/// The scope-approval gate: what opens under the command row before a
/// whole-document generation request is even sent.
///
/// This is the one moment Mancia asks permission before it acts rather than
/// after — a whole-document request means every word in the document leaves
/// the Mac, which a per-selection request never implies. The copy says so
/// plainly rather than hiding it behind "Document" as the target chip's own
/// label, and Decline is the default focus so a stray Return never approves
/// it by accident.
struct RibbonScopeApprovalView: View {
    @Bindable var model: PanelModel
    var focus: FocusState<PanelModel.Cell?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RibbonPalette.text)
                Text(
                    "Mancia will read the entire document and send it to Copilot. "
                        + "Its contents may leave this Mac."
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(RibbonPalette.caption)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                GhostButton("Decline", tint: RibbonPalette.caption) {
                    model.onDeclinePending?()
                }
                .focusable()
                .focused(focus, equals: .scopeDecline)
                .ribbonFocusRing(model.focusedCell == .scopeDecline, radius: 8, inset: -2)
                .accessibilityIdentifier("DeclineScope")
                AccentButton(
                    "Send document", fill: RibbonPalette.action, foreground: RibbonPalette.onAction
                ) {
                    model.onApproveDocumentGeneration?()
                }
                .focusable()
                .focused(focus, equals: .scopeApprove)
                .ribbonFocusRing(model.focusedCell == .scopeApprove, radius: 8, inset: -2)
                .accessibilityLabel("Send whole document to Copilot")
                .accessibilityIdentifier("ApproveScope")
            }
            .frame(height: 30)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        model.pendingScopeApprovalActionTitle.isEmpty
            ? "Send the whole document?"
            : "\(model.pendingScopeApprovalActionTitle) the whole document?"
    }
}
