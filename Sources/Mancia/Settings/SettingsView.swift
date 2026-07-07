import SwiftUI
import KeyboardShortcuts

/// The app's settings window content.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let provider: LLMProvider

    @State private var providerStatus: ProviderStatus = .ready
    @State private var checking = false
    @State private var models: [CopilotModel] = []

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Edit Selection:", name: .editSelection)
            }

            Section("GitHub Copilot CLI") {
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
                        .fill(providerStatus == .ready ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(providerStatus.label)
                        .foregroundStyle(.secondary)
                        .help(providerStatus.detail)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Check") { Task { await refreshStatus() } }
                }
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
        checking = true
        providerStatus = await provider.checkAvailability()
        checking = false
    }
}
