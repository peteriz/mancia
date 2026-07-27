import SwiftUI
import AppKit
import KeyboardShortcuts

/// The app's settings window content.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let provider: LLMProvider

    /// The command that installs the Copilot CLI, shown when it isn't found.
    private static let installCommand = "npm install -g @github/copilot"
    private static let docsURL = URL(string: "https://docs.github.com/copilot/concepts/agents/about-copilot-cli")!

    @State private var providerStatus: ProviderStatus = .ready
    @State private var checking = false
    @State private var models: [CopilotModel] = [CopilotModel(id: "auto", name: "Auto")]
    @State private var detectFeedback: String?
    /// The CLI's on-disk cache, kept as the metadata donor for merges and as
    /// the list to fall back to when the live listing is unavailable.
    @State private var cachedModels: [CopilotModel] = []
    /// True once a live listing attempt has come back empty. Surfaced in the
    /// UI so falling back to a possibly-stale cache is visible rather than
    /// looking like the CLI genuinely offers nothing new.
    @State private var liveListingFailed = false

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Edit Selection:") {
                    ShortcutRecorderView(name: .editSelection)
                }
            }

            Section("GitHub Copilot CLI") {
                Picker("Model:", selection: $settings.copilotModel) {
                    Text("Default").tag("")
                    // Grouped fastest-first (Fastest → Balanced → Most
                    // capable); the special "auto" cache entry is excluded
                    // from the tiers since the row above already covers it.
                    ForEach(modelTiers) { tier in
                        Section(tier.title) {
                            ForEach(tier.models) { model in
                                Text(modelLabel(for: model)).tag(model.id)
                            }
                        }
                    }
                }
                if liveListingFailed {
                    HStack(spacing: 6) {
                        Text("Showing cached models — couldn't read the current list from the CLI, so newly released models may be missing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { Task { await refreshLiveModels() } }
                            .controlSize(.small)
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
                    Button("Detect") { detect() }
                }
                if let detectFeedback {
                    Text(detectFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statusRow
                if providerStatus != .ready {
                    remediation
                }
            }

            Section("General") {
                Picker("After applying:", selection: $settings.postApplyBehavior) {
                    ForEach(PostApplyBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                Toggle("Confirm before replacing the whole document", isOn: $settings.confirmWholeDocumentReplace)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 540)
        .task {
            let stored = settings.copilotModel
            let cached = await Task.detached { CopilotModelCatalog.modelsForPicker(storedModel: stored) }.value
            cachedModels = cached
            models = cached
            // Check status first: it is a fast `--version` call, while the live
            // listing has to wait on the ACP sidecar starting up.
            await refreshStatus()
            await refreshLiveModels()
        }
    }

    // MARK: - Status & guidance

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(providerStatus.label)
                .foregroundStyle(.secondary)
            if checking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Check") { Task { await refreshStatus() } }
                .disabled(checking)
        }
    }

    /// Inline, always-visible guidance for a non-ready provider, plus a
    /// context button so the user has a concrete next step rather than a
    /// hover-only tooltip.
    @ViewBuilder
    private var remediation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(providerStatus.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                switch providerStatus {
                case .notFound:
                    Button("Copy install command") {
                        copyToPasteboard(Self.installCommand)
                        detectFeedback = "Copied: \(Self.installCommand)"
                    }
                case .error where isNotSignedIn:
                    Text("Run `copilot` once in Terminal to sign in, then Check again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Link("Copilot CLI docs", destination: Self.docsURL)
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        switch providerStatus {
        case .ready: return .green
        case .notFound: return .orange
        case .error: return .red
        }
    }

    private var isNotSignedIn: Bool {
        if case .error(let message) = providerStatus {
            return message.lowercased().contains("sign")
        }
        return false
    }

    /// Models grouped into latency tiers, fastest first, for the sectioned
    /// picker above.
    private var modelTiers: [ModelTier] {
        CopilotModelCatalog.tiered(models)
    }

    /// The measured ultra-fast default, so its row can be marked.
    private var recommendedModelID: String? {
        CopilotModelCatalog.recommendedFastModel(from: models)
    }

    private func modelLabel(for model: CopilotModel) -> String {
        model.id == recommendedModelID ? "\(model.name) (Recommended)" : model.name
    }

    /// Effort levels for the picker: the selected model's supported levels when
    /// the cache knows them, else all CLI levels; always includes the stored
    /// value so the picker binding stays valid.
    private var reasoningEffortOptions: [String] {
        var options = models.first { $0.id == settings.copilotModel }?.supportedReasoningEfforts
            ?? CopilotModelCatalog.reasoningEfforts(in: models)
        let stored = settings.reasoningEffort
        if !stored.isEmpty, !options.contains(stored) { options.append(stored) }
        return options
    }

    private func detect() {
        let resolved = CopilotCLIProvider.resolveExecutable(override: nil)
        if resolved == "/usr/bin/env" {
            settings.copilotPath = ""
            detectFeedback = "Not found in standard locations. Ensure the CLI is installed, or set the path manually."
        } else {
            settings.copilotPath = resolved
            detectFeedback = "Found at \(resolved)"
        }
        Task { await refreshStatus() }
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    /// Replace the cached picker list with what the CLI actually offers now.
    ///
    /// `~/.copilot/data.db` only gets rewritten when the interactive Copilot
    /// TUI runs, so on a machine that only ever drives Copilot through Mancia
    /// it can be badly stale and hide newly released models. Asking the running
    /// CLI reuses the sidecar's warm session, and a failure leaves the cached
    /// list in place — flagged in the UI rather than passed off as current.
    private func refreshLiveModels() async {
        guard let provider = provider as? ModelListingProvider else { return }
        let live = await provider.availableModels()
        guard !live.isEmpty else {
            models = cachedModels
            liveListingFailed = true
            return
        }
        liveListingFailed = false
        var merged = CopilotModelCatalog.merged(live: live, cached: cachedModels)
        let stored = settings.copilotModel.trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty, !merged.contains(where: { $0.id == stored }) {
            merged.append(CopilotModel(id: stored, name: stored))
        }
        models = merged
    }

    private func refreshStatus() async {
        checking = true
        providerStatus = await provider.checkAvailability()
        checking = false
    }
}
