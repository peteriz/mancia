import SwiftUI

/// Compact SwiftUI content for the floating edit panel.
struct EditPanelView: View {
    @Bindable var model: PanelModel

    private let actions: [EditAction] = [.rewrite, .summarize, .fixGrammar, .translate, .reply]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.phase {
            case .input: inputView
            case .running: runningView
            case .result: resultView
            case .error: errorView
            }
        }
        .padding(14)
        .frame(width: 380)
        .onExitCommand { model.onCancel?() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.tint)
            Text("AI-Edit")
                .font(.headline)
            Spacer()
            scopePicker
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $model.scope) {
            Text(model.hasSelection ? "Selection (\(model.selectionCharCount))" : "Selection")
                .tag(PanelModel.Scope.selection)
            Text("Entire document").tag(PanelModel.Scope.document)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
        .disabled(!model.hasSelection && model.phase != .input)
        .onAppear {
            if !model.hasSelection { model.scope = .document }
        }
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(actions, id: \.title) { action in
                    Button {
                        model.onPerform?(action)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: action.symbol)
                            Text(action.title)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(scopeUnavailable)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier(action.title)
                }
            }
            TextField("Or tell the AI what to do…", text: $model.instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitInstruction() }
                .disabled(scopeUnavailable)
                .accessibilityLabel("Custom instruction")
                .accessibilityIdentifier("CustomInstruction")
        }
    }

    private var runningView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Asking Copilot…")
            Spacer()
            Button("Cancel") { model.onCancel?() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("Cancel")
        }
        .padding(.vertical, 6)
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(model.resultText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Apply") { model.onApply?() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Apply")
                    .accessibilityIdentifier("Apply")
                Button("Copy") { model.onCopy?() }
                    .accessibilityLabel("Copy")
                    .accessibilityIdentifier("Copy")
                Button("Retry") { model.onRetry?() }
                    .accessibilityLabel("Retry")
                    .accessibilityIdentifier("Retry")
                Spacer()
                Button("Cancel") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("Cancel")
            }
        }
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.errorText, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Retry") { model.onRetry?() }
                    .accessibilityLabel("Retry")
                    .accessibilityIdentifier("Retry")
                Spacer()
                Button("Close") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("Close")
            }
        }
    }

    private var scopeUnavailable: Bool {
        model.scope == .selection && !model.hasSelection
    }
}
