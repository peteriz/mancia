import SwiftUI
import KeyboardShortcuts

/// The app's settings window content.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let registry: ProviderRegistry

    @State private var providerStatus: ProviderStatus = .ready
    @State private var checking = false
    @State private var models: [CopilotModel] = []

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Edit Selection:", name: .editSelection)
            }

            Section("Provider") {
                Picker("Provider:", selection: .constant(0)) {
                    Text("GitHub Copilot CLI").tag(0)
                }
                .disabled(true)
                Picker("Model:", selection: $settings.copilotModel) {
                    Text("Default").tag("")
                    ForEach(models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                Picker("Reasoning effort:", selection: $settings.reasoningEffort) {
                    Text("Default").tag("")
                    ForEach(reasoningEffortOptions, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
                HStack {
                    TextField("Copilot path:", text: $settings.copilotPath, prompt: Text("Auto-detect"))
                    Button("Detect") { settings.copilotPath = detectedPath() }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .help(statusTooltip)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Check") { Task { await refreshStatus() } }
                }
                Text("More providers coming soon.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 540)
        .task {
            models = CopilotModelCatalog.modelsForPicker(storedModel: settings.copilotModel)
            await refreshStatus()
        }
    }

    /// Effort levels for the picker: the selected model's supported levels when
    /// the cache knows them, else all CLI levels; always includes the stored
    /// value so the picker binding stays valid.
    private var reasoningEffortOptions: [String] {
        var options = models.first { $0.id == settings.copilotModel }?.supportedReasoningEfforts
            ?? CopilotModelCatalog.allReasoningEfforts
        let stored = settings.reasoningEffort
        if !stored.isEmpty, !options.contains(stored) { options.append(stored) }
        return options
    }

    private func detectedPath() -> String {
        let resolved = CopilotCLIProvider.resolveExecutable(override: nil)
        return resolved == "/usr/bin/env" ? "" : resolved
    }

    private func refreshStatus() async {
        guard let provider = registry.current else { return }
        checking = true
        providerStatus = await provider.checkAvailability()
        checking = false
    }

    private var statusColor: Color {
        switch providerStatus {
        case .ready: return .green
        case .notFound, .error: return .red
        }
    }

    private var statusText: String {
        switch providerStatus {
        case .ready: return "Ready"
        case .notFound: return "Not found"
        case .error: return "Error"
        }
    }

    private var statusTooltip: String {
        switch providerStatus {
        case .ready: return "Copilot CLI is available."
        case .notFound: return ProviderError.notFound.localizedDescription
        case .error(let message): return message
        }
    }
}
