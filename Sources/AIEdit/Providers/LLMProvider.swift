import Foundation

/// Availability of a provider, surfaced in menus and settings.
enum ProviderStatus: Sendable, Equatable {
    case ready
    case notFound
    case error(String)

    var isReady: Bool { self == .ready }
}

/// A pluggable large-language-model backend.
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func complete(_ prompt: String) async throws -> String
    func checkAvailability() async -> ProviderStatus
}

/// Holds the providers available to the app. Only Copilot for now; the shape
/// is the extension point for future backends.
final class ProviderRegistry: Sendable {
    let providers: [LLMProvider]

    init(providers: [LLMProvider]) {
        self.providers = providers
    }

    /// The currently selected provider (first available for now).
    var current: LLMProvider? { providers.first }

    static func makeDefault(settings: AppSettings) -> ProviderRegistry {
        ProviderRegistry(providers: [CopilotCLIProvider(settings: settings)])
    }
}
