import AppKit
import SwiftUI

/// The floating edit panel — the "sharp & effective" design: a warm cream/ink
/// surface with one decisive vermilion accent on the hero **Improve** action.
///
/// Fixed size, never relayouts mid-use: the field and Improve button are always
/// present. While a request runs the field dims and locks, but the Improve
/// button stays vibrant and *becomes* the progress — an indeterminate bar
/// sweeps its base edge — so the panel reads as fast and working, not frozen.
/// The one-line status at the bottom swaps between idle / running / applied /
/// error. Enter routes to Improve when the field is empty, or the typed
/// instruction when it isn't.
struct EditPanelView: View {
    @Bindable var model: PanelModel
    @FocusState private var fieldFocused: Bool

    private let width: CGFloat = 312

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
                .padding(.bottom, 11)

            VStack(alignment: .leading, spacing: 8) {
                field
                    .disabled(fieldLocked)
                    .opacity(fieldLocked ? 0.42 : 1)
                    .animation(.easeInOut(duration: 0.2), value: model.phase)
                improveButton
            }

            statusLine
                .padding(.top, 10)
                .frame(height: 20)
        }
        .padding(12)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 14)
        .onExitCommand { model.onCancel?() }
        .onAppear { fieldFocused = true }
        .onChange(of: model.sessionSeq) { fieldFocused = true }
        .onChange(of: model.focusSeq) { fieldFocused = true }
    }

    private var isRunning: Bool { model.phase == .running }
    private var isConfirming: Bool { model.phase == .confirm }
    /// The instruction field is inert while a request runs or a whole-document
    /// replacement is awaiting confirmation.
    private var fieldLocked: Bool { isRunning || isConfirming }
    private var hasCustomInstruction: Bool {
        !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Brand row

    private var brandRow: some View {
        HStack(spacing: 7) {
            BrandMark.view(size: 15)
            Text("Mancia")
                .font(.system(size: 13, weight: .bold))
                .tracking(-0.1)
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            scopeCaption
        }
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private var scopeCaption: some View {
        if model.capturing {
            Text("Reading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        } else if model.hasSelection {
            Menu {
                Button("Selection · \(model.selectionCharCount)") { model.scope = .selection }
                Button("Entire document") { model.scope = .document }
            } label: {
                HStack(spacing: 3) {
                    Text(scopeText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Scope")
            .accessibilityIdentifier("Scope")
        } else {
            Text("Entire document")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var scopeText: String {
        switch model.scope {
        case .selection: return "Selection · \(model.selectionCharCount)"
        case .document: return "Entire document"
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 8) {
            TextField("", text: $model.instruction, prompt: placeholder)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
                .focused($fieldFocused)
                .onSubmit { model.runPrimary() }
                .accessibilityLabel("Custom instruction")
                .accessibilityIdentifier("CustomInstruction")

            Button { model.submitInstruction() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hasCustomInstruction ? Palette.text : Palette.textFaint)
            }
            .buttonStyle(.plain)
            .disabled(!hasCustomInstruction)
            .help("Run custom instruction")
            .accessibilityLabel("Run custom instruction")
            .accessibilityIdentifier("CustomSubmit")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(fieldFocused ? Palette.text.opacity(0.28) : Palette.border, lineWidth: 1)
        )
    }

    private var placeholder: Text {
        Text("Describe a change…").foregroundColor(Palette.textFaint)
    }

    // MARK: - Improve button

    private var improveButton: some View {
        Button { heroAction() } label: {
            HStack(spacing: 7) {
                if isConfirming {
                    Text("Replace document")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.05)
                    Text("↵")
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.7)
                } else if isRunning {
                    Text("\(runningLabel)…")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.05)
                } else {
                    Text("Improve")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.05)
                    if !hasCustomInstruction {
                        Text("↵")
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0.7)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(Palette.onAccent)
            .background(Palette.accent)
            .overlay(alignment: .bottom) {
                if isRunning {
                    IndeterminateBar(tint: Palette.onAccent)
                        .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isRunning)
        .accessibilityLabel(isConfirming ? "Replace document" : "Improve")
        .accessibilityIdentifier(isConfirming ? "ReplaceDocument" : "Improve")
    }

    /// Route the hero button: apply the pending replacement while confirming,
    /// otherwise run the Improve action.
    private func heroAction() {
        if isConfirming {
            model.onConfirmApply?()
        } else {
            model.onPerform?(.improve)
        }
    }

    /// The verb shown inside the button while it runs. Stays honest during the
    /// brief background-capture window before the provider call begins.
    private var runningLabel: String {
        if model.capturing { return "Reading selection" }
        return model.runningTitle.isEmpty ? "Improving" : model.runningTitle
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .idle: idleStatus
        case .running: runningStatus
        case .confirm: confirmStatus
        case .applied: appliedStatus
        case .error: errorStatus
        }
    }

    private var idleStatus: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text(model.capturing ? "Reading selection…" : idleHint)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1)
    }

    private var idleHint: String {
        switch model.scope {
        case .selection: return "Ready · replaces your selection"
        case .document: return "Ready · edits the whole document"
        }
    }

    private var runningStatus: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            GhostButton("Cancel") { model.onCancelRun?() }
                .accessibilityIdentifier("Cancel")
        }
        .padding(.horizontal, 1)
    }

    /// Awaiting confirmation before a whole-document overwrite. Shows the size
    /// change as a signal (e.g. a document collapsing to a few characters) and
    /// offers Cancel; the hero button becomes "Replace document".
    private var confirmStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text("Review · \(ApplyConfirmation.summary(originalCharacters: model.pendingOriginalCharCount, resultCharacters: model.pendingResultCharCount))")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            GhostButton("Cancel") { model.onCancelRun?() }
                .accessibilityIdentifier("ConfirmCancel")
        }
        .padding(.horizontal, 1)
    }

    private var appliedStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.applied).frame(width: 7, height: 7)
            Text("Improved")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            if model.versionCount > 1 {
                Text("·").foregroundStyle(Palette.textSecondary.opacity(0.5))
                versionNav
            }
            Spacer(minLength: 0)
            Button("Done") { model.onCancel?() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Palette.accent)
                .accessibilityIdentifier("Done")
        }
        .padding(.horizontal, 1)
    }

    private var versionNav: some View {
        HStack(spacing: 6) {
            Button { model.onNavigate?(model.currentIndex - 1) } label: {
                Image(systemName: "chevron.backward").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.currentIndex == 0 ? Palette.textFaint : Palette.textSecondary)
            .disabled(model.currentIndex == 0)
            .accessibilityLabel("Previous version")
            .accessibilityIdentifier("IterBack")

            Text("\(model.currentIndex + 1)/\(model.versionCount)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("IterCounter")

            Button { model.onNavigate?(model.currentIndex + 1) } label: {
                Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.currentIndex >= model.versionCount - 1 ? Palette.textFaint : Palette.textSecondary)
            .disabled(model.currentIndex >= model.versionCount - 1)
            .accessibilityLabel("Next version")
            .accessibilityIdentifier("IterForward")
        }
    }

    private var errorStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.errorDot).frame(width: 7, height: 7)
            Text(model.errorText.isEmpty ? "Provider failed" : model.errorText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.error)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            GhostButton("Close") { model.onCancel?() }
                .accessibilityIdentifier("Close")
            GhostButton("Retry", tint: Palette.error) { model.onRetry?() }
                .accessibilityIdentifier("Retry")
        }
        .padding(.horizontal, 1)
    }
}

/// A small hairline-bordered secondary button used in the status line.
private struct GhostButton: View {
    let title: String
    var tint: Color
    let action: () -> Void

    init(_ title: String, tint: Color = Palette.textSecondary, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// An indeterminate progress rail that sweeps along the base of the running
/// Improve button — the panel's single, decisive "working" signal. A capsule
/// segment glides left-to-right over a faint track, looping until the phase
/// leaves `.running` and the overlay is removed.
private struct IndeterminateBar: View {
    var tint: Color
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let segment = max(30, w * 0.4)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.20))
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.9))
                    .frame(width: segment)
                    .offset(x: animate ? w : -segment)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}
