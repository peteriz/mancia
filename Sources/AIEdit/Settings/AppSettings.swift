import Foundation
import Observation
import ServiceManagement

/// UserDefaults-backed, observable app settings. Main-actor isolated because it
/// drives the UI and touches login-item registration.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let copilotPath = "copilotPath"
        static let copilotModel = "copilotModel"
        static let targetLanguage = "targetLanguage"
    }

    private let defaults: UserDefaults

    var copilotPath: String {
        didSet { defaults.set(copilotPath, forKey: Key.copilotPath) }
    }
    var copilotModel: String {
        didSet { defaults.set(copilotModel, forKey: Key.copilotModel) }
    }
    var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: Key.targetLanguage) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.copilotPath = defaults.string(forKey: Key.copilotPath) ?? ""
        self.copilotModel = defaults.string(forKey: Key.copilotModel) ?? ""
        self.targetLanguage = defaults.string(forKey: Key.targetLanguage) ?? "English"
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
                NSLog("AI-Edit: launch-at-login toggle failed: \(error.localizedDescription)")
            }
        }
    }
}
