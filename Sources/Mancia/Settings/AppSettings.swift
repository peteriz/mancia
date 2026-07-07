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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.copilotPath = (defaults.string(forKey: Key.copilotPath) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.copilotModel = (defaults.string(forKey: Key.copilotModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningEffort = (defaults.string(forKey: Key.reasoningEffort) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.postApplyBehavior = defaults.string(forKey: Key.postApplyBehavior)
            .flatMap(PostApplyBehavior.init(rawValue:)) ?? .hybrid
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
