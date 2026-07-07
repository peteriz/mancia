import Foundation
import SwiftUI

/// Compact, Writing Tools-style SwiftUI content for the floating edit panel.
/// The describe field and preset action buttons are always visible; a status
/// strip at the bottom cycles through idle / running / applied / error.
struct EditPanelView: View {
    @Bindable var model: PanelModel

    private let actions: [EditAction] = [.fixGrammar, .rewrite, .summarize]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Everything except the status strip's Cancel is disabled and
            // dimmed while a provider request is in flight.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Describe your change…", text: $model.instruction)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.submitInstruction() }
                        .accessibilityLabel("Custom instruction")
                        .accessibilityIdentifier("CustomInstruction")
                    Button { model.submitInstruction() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasCustomInstruction)
                    .help("Run custom instruction")
                    .accessibilityLabel("Run custom instruction")
                    .accessibilityIdentifier("CustomSubmit")
                }
                HStack(spacing: 8) {
                    ForEach(actions, id: \.title) { action in
                        ActionButton(action: action) { model.onPerform?(action) }
                    }
                }
            }
            .disabled(isRunning)
            .opacity(isRunning ? 0.4 : 1)
            Divider()
            statusStrip
        }
        .padding(10)
        .frame(width: 310)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onExitCommand { model.onCancel?() }
    }

    private var isRunning: Bool { model.phase == .running }
    private var hasCustomInstruction: Bool {
        !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        switch model.phase {
        case .idle: idleStrip
        case .running: runningStrip
        case .applied: appliedStrip
        case .error: errorStrip
        }
    }

    /// One-line subtle scope caption; a small menu allows switching scope
    /// when a selection exists.
    private var idleStrip: some View {
        HStack(spacing: 4) {
            if model.hasSelection {
                Menu {
                    Button("Selection · \(model.selectionCharCount) chars") { model.scope = .selection }
                    Button("Entire document") { model.scope = .document }
                } label: {
                    Text(scopeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Scope")
                .accessibilityIdentifier("Scope")
            } else {
                Text("Entire document")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 2)
    }

    private var scopeText: String {
        switch model.scope {
        case .selection: return "Selection · \(model.selectionCharCount) chars"
        case .document: return "Entire document"
        }
    }

    private var runningStrip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.runningTitle.isEmpty ? "Working…" : "\(model.runningTitle)…")
                .font(.callout)
            Spacer()
            Button("Cancel") { model.onCancelRun?() }
                .controlSize(.small)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("Cancel")
        }
        .padding(.vertical, 2)
    }

    /// Iteration navigation: ← 2/3 → plus Done. versions[0] is the session
    /// original; each applied result appends a version.
    private var appliedStrip: some View {
        HStack(spacing: 8) {
            Button {
                model.onNavigate?(model.currentIndex - 1)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .controlSize(.small)
            .disabled(model.currentIndex == 0)
            .accessibilityLabel("Previous version")
            .accessibilityIdentifier("IterBack")
            Text("\(model.currentIndex + 1)/\(model.versionCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("IterCounter")
            Button {
                model.onNavigate?(model.currentIndex + 1)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .controlSize(.small)
            .disabled(model.currentIndex >= model.versionCount - 1)
            .accessibilityLabel("Next version")
            .accessibilityIdentifier("IterForward")
            Spacer()
            Button("Done") { model.onCancel?() }
                .controlSize(.small)
                .accessibilityLabel("Done")
                .accessibilityIdentifier("Done")
        }
        .padding(.vertical, 2)
    }

    private var errorStrip: some View {
        HStack(spacing: 8) {
            Label(model.errorText, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry") { model.onRetry?() }
                .controlSize(.small)
                .accessibilityLabel("Retry")
                .accessibilityIdentifier("Retry")
        }
        .padding(.vertical, 2)
    }
}

/// Equal-width preset action button for the compact popout.
private struct ActionButton: View {
    let action: EditAction
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(action.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(hovering ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.title)
    }
}
