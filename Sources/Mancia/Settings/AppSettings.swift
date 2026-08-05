import Foundation
import Observation
import ServiceManagement

/// What the panel does once an edit has been applied to the target document.
enum PostApplyBehavior: String, CaseIterable, Identifiable, Sendable {
    /// Flash "Improved", then auto-close after a short beat; any keypress during
    /// the beat keeps the panel open so the user can iterate.
    case hybrid
    /// Keep the panel open for another action or ⌘Z until the user closes it.
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
        static let copilotModelIsDerived = "copilotModelIsDerived"
        static let reasoningEffort = "reasoningEffort"
        static let postApplyBehavior = "postApplyBehavior"
        static let confirmWholeDocumentReplace = "confirmWholeDocumentReplace"
    }

    private let defaults: UserDefaults

    var copilotPath: String {
        didSet { defaults.set(copilotPath, forKey: Key.copilotPath) }
    }
    var copilotModel: String {
        didSet {
            defaults.set(copilotModel, forKey: Key.copilotModel)
            // Every assignment from outside `init` is a user choice, which
            // freezes the value; `adoptDerivedDefault` re-marks its own write.
            copilotModelIsDerived = false
        }
    }
    /// True while `copilotModel` holds a value this app derived rather than one
    /// the user chose.
    ///
    /// First-run resolution happens in `init`, which can only see the on-disk
    /// cache — and that cache carries no `usageMultiplier`, so it cannot rank
    /// on the one live signal the recommendation is built around, and it can
    /// name a model the backend has since retired. This flag keeps the derived
    /// value revisable until the user expresses a preference, so the first live
    /// catalog can correct it. Absent for installs that pre-date the flag,
    /// which therefore read as user choices and are never touched.
    private(set) var copilotModelIsDerived: Bool {
        didSet { defaults.set(copilotModelIsDerived, forKey: Key.copilotModelIsDerived) }
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
        // non-empty). Only the first state gets the derived low-latency
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
            self.copilotModelIsDerived = defaults.bool(forKey: Key.copilotModelIsDerived)
        } else {
            let catalog = modelCatalog()
            let recommended = CopilotModelCatalog.recommendedFastModel(from: catalog) ?? ""
            self.copilotModel = recommended
            // Provisional: ranked from the cache, which carries no usage
            // multiplier. `adoptDerivedDefault` revisits this once a live
            // catalog exists.
            self.copilotModelIsDerived = !recommended.isEmpty
            self.reasoningEffort = (defaults.string(forKey: Key.reasoningEffort) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !recommended.isEmpty {
                defaults.set(recommended, forKey: Key.copilotModel)
                defaults.set(true, forKey: Key.copilotModelIsDerived)
                // `--reasoning-effort none`, where the chosen model supports
                // it, is what makes the default ultra-fast rather than merely
                // lightweight. Carry it along on this same first-run path
                // (and only this path); an explicit reasoningEffort choice is
                // never touched, matching the copilotModel contract above.
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

    /// Re-derive the auto-chosen model now that a live catalog is available,
    /// and report whether it changed.
    ///
    /// `init` can only rank the on-disk cache, which has no usage multipliers
    /// and may list retired models. This corrects that pick the first time a
    /// real catalog arrives. It is a no-op once the user has chosen a model —
    /// an explicit choice is never overridden, matching the `copilotModel`
    /// contract in `init` — and it only ever moves the selection to the
    /// cheapest model in the fastest tier, so it cannot silently escalate cost.
    ///
    /// `reasoningEffort` is deliberately left alone: `init` already resolved it
    /// on the same first-run path, and re-deciding it here would risk undoing a
    /// deliberate choice for no latency gain within one tier.
    @discardableResult
    func adoptDerivedDefault(from catalog: [CopilotModel]) -> Bool {
        guard copilotModelIsDerived,
              let recommended = CopilotModelCatalog.recommendedFastModel(from: catalog),
              recommended != copilotModel else { return false }
        copilotModel = recommended      // clears the flag via didSet…
        copilotModelIsDerived = true    // …so re-mark it as still derived
        return true
    }

    /// Clear a stale model/effort pair after fresher metadata arrives.
    @discardableResult
    func reconcileReasoningEffort(with catalog: [CopilotModel]) -> Bool {
        let validated = CopilotModelCatalog.validatedReasoningEffort(
            reasoningEffort, for: copilotModel, in: catalog)
        guard validated != reasoningEffort else { return false }
        reasoningEffort = validated
        return true
    }

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
