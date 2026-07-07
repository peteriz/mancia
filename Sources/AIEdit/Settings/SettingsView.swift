import SwiftUI
import KeyboardShortcuts

/// The app's settings window content.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let registry: ProviderRegistry

    @State private var providerStatus: ProviderStatus = .ready
    @State private var checking = false

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
                TextField("Model:", text: $settings.copilotModel, prompt: Text("auto"))
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

            Section("Translation") {
                TextField("Target language:", text: $settings.targetLanguage, prompt: Text("English"))
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .task { await refreshStatus() }
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
