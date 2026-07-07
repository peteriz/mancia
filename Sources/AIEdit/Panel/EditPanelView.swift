import SwiftUI

/// Compact, Writing Tools-style SwiftUI content for the floating edit panel.
/// The describe field and action rows are always visible; a status strip at
/// the bottom cycles through idle / running / applied / error.
struct EditPanelView: View {
    @Bindable var model: PanelModel

    private let actions: [EditAction] = [.fixGrammar, .rewrite, .summarize]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Describe your change…", text: $model.instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitInstruction() }
                .accessibilityLabel("Custom instruction")
                .accessibilityIdentifier("CustomInstruction")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(actions, id: \.title) { action in
                    ActionRow(action: action) { model.onPerform?(action) }
                }
            }
            Divider()
            statusStrip
        }
        .padding(10)
        .frame(width: 310)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onExitCommand { model.onCancel?() }
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

    private var appliedStrip: some View {
        HStack(spacing: 8) {
            Picker("Version", selection: versionBinding) {
                Text("Original").tag(PanelModel.Version.original)
                Text("Rewritten").tag(PanelModel.Version.rewritten)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Version")
            .accessibilityIdentifier("VersionToggle")
            Spacer()
            Button("Done") { model.onCancel?() }
                .controlSize(.small)
                .accessibilityLabel("Done")
                .accessibilityIdentifier("Done")
        }
        .padding(.vertical, 2)
    }

    /// Routes segment changes through the coordinator so it can drive the
    /// target app's undo stack / re-apply path.
    private var versionBinding: Binding<PanelModel.Version> {
        Binding(
            get: { model.appliedVersion },
            set: { model.onSelectVersion?($0) }
        )
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

/// A Writing Tools-style action row: icon + label with a hover highlight.
private struct ActionRow: View {
    let action: EditAction
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: action.symbol)
                    .frame(width: 18)
                    .foregroundStyle(.tint)
                Text(action.title)
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                hovering ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.title)
    }
}
