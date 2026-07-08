import Foundation

/// Availability of a provider, surfaced in menus and settings.
enum ProviderStatus: Sendable, Equatable {
    case ready
    case notFound
    case error(String)

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .notFound: return "Not found"
        case .error: return "Error"
        }
    }

    var detail: String {
        switch self {
        case .ready: return "Copilot CLI is available."
        case .notFound: return ProviderError.notFound.localizedDescription
        case .error(let message): return message
        }
    }

    var menuMark: String {
        switch self {
        case .ready: return "✓"
        case .notFound, .error: return "⚠︎"
        }
    }
}

/// A pluggable large-language-model backend.
protocol LLMProvider: Sendable {
    var displayName: String { get }
    func complete(_ prompt: String) async throws -> String
    func checkAvailability() async -> ProviderStatus
}

/// Optional latency hook for providers that can keep a one-shot session warm
/// while the floating panel is open.
protocol WarmableLLMProvider: LLMProvider {
    func prepareForPanel() async
    func panelDidClose() async
}
