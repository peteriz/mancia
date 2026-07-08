import Foundation
import Observation
import ServiceManagement

/// What the panel does once an edit has been applied to the target document.
enum PostApplyBehavior: String, CaseIterable, Identifiable, Sendable {
    /// Flash "Improved", then auto-close after a short beat; any keypress during
    /// the beat keeps the panel open so the user can iterate.
    case hybrid
    /// Keep the panel open with version navigation until the user closes it.
    case stayOpen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hybrid: return "Flash and close"
        case .stayOpen: return "Stay open"
        }
    }
}

/// UserDefaults-backed, observable app settings. Main-actor isolated because it
/// drives the UI and touches login-item registration.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let copilotPath = "copilotPath"
        static let copilotModel = "copilotModel"
        static let reasoningEffort = "reasoningEffort"
        static let postApplyBehavior = "postApplyBehavior"
        static let confirmWholeDocumentReplace = "confirmWholeDocumentReplace"
    }

    private let defaults: UserDefaults

    var copilotPath: String {
        didSet { defaults.set(copilotPath, forKey: Key.copilotPath) }
    }
    var copilotModel: String {
        didSet { defaults.set(copilotModel, forKey: Key.copilotModel) }
    }
    /// Reasoning-effort level for the Copilot CLI; empty = provider default
    /// (no `--reasoning-effort` flag passed).
    var reasoningEffort: String {
        didSet { defaults.set(reasoningEffort, forKey: Key.reasoningEffort) }
    }
    /// What the panel does after an edit is applied.
    var postApplyBehavior: PostApplyBehavior {
        didSet { defaults.set(postApplyBehavior.rawValue, forKey: Key.postApplyBehavior) }
    }
    /// When true (default), a whole-document replacement pauses for explicit
    /// confirmation before it overwrites the document. Selection edits are never
    /// gated — they are low blast-radius and trivially undone.
    var confirmWholeDocumentReplace: Bool {
        didSet { defaults.set(confirmWholeDocumentReplace, forKey: Key.confirmWholeDocumentReplace) }
    }

    /// Designated initializer. `modelCatalog` is injected (rather than always
    /// reading `~/.copilot/data.db` directly) so the first-run recommendation
    /// below is unit-testable with a fixed model list.
    init(defaults: UserDefaults = .standard, modelCatalog: () -> [CopilotModel] = { CopilotModelCatalog.loadModels() ?? [] }) {
        self.defaults = defaults
        self.copilotPath = (defaults.string(forKey: Key.copilotPath) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // First-run recommendation: `copilotModel` has three meaningful states
        // — "never chosen" (key absent), "explicitly Default/auto" (key
        // present, value ""), and "explicitly some model" (key present,
        // non-empty). Only the first state gets the measured ultra-fast
        // default; both explicit states — including explicit auto — are read
        // back verbatim and never touched again. Resolving here (once, at
        // settings-load time) and persisting the result means the Settings
        // picker shows a real, marked selection instead of a "Default"
        // placeholder whose effect the user can't see, and every other
        // reader of `copilotModel` (the provider, the picker) sees one
        // consistent value with no extra indirection.
        if defaults.object(forKey: Key.copilotModel) != nil {
            self.copilotModel = (defaults.string(forKey: Key.copilotModel) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.reasoningEffort = (defaults.string(forKey: Key.reasoningEffort) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let catalog = modelCatalog()
            let recommended = CopilotModelCatalog.recommendedFastModel(from: catalog) ?? ""
            self.copilotModel = recommended
            self.reasoningEffort = (defaults.string(forKey: Key.reasoningEffort) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !recommended.isEmpty {
                defaults.set(recommended, forKey: Key.copilotModel)
                // The benchmark that picked `recommended` timed it with
                // `--reasoning-effort none` where the model supports "none" —
                // that flag is what makes it ultra-fast rather than merely
                // lightweight. Carry it along on this same first-run path
                // (and only this path) so the default actually delivers the
                // measured speed; an explicit reasoningEffort choice is never
                // touched, matching the copilotModel contract above.
                if defaults.object(forKey: Key.reasoningEffort) == nil,
                   let match = catalog.first(where: { $0.id == recommended }),
                   match.supportedReasoningEfforts?.contains("none") == true {
                    // `didSet` never fires for property assignments made
                    // inside a class's own initializer (verified: even a
                    // second assignment to the same property is silent), so
                    // this needs its own explicit persist.
                    self.reasoningEffort = "none"
                    defaults.set("none", forKey: Key.reasoningEffort)
                }
            }
        }

        self.postApplyBehavior = defaults.string(forKey: Key.postApplyBehavior)
            .flatMap(PostApplyBehavior.init(rawValue:)) ?? .hybrid
        // Default on: absent key means the safety gate is enabled.
        self.confirmWholeDocumentReplace =
            defaults.object(forKey: Key.confirmWholeDocumentReplace) as? Bool ?? true
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Mancia: launch-at-login toggle failed: \(error.localizedDescription)")
            }
        }
    }
}
