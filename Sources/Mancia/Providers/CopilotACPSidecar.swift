import Foundation

/// Keeps one Copilot ACP process alive and one empty session warm.
///
/// The warm session is single-use: once a prompt is sent, the session id is
/// discarded so selected text never carries into a later edit.
actor CopilotACPSidecar {
    typealias Client = any CopilotACPClientProtocol
    typealias ClientFactory = @Sendable (CopilotACPConfig) async throws -> Client

    /// A bounded lifetime lets the menu-bar app pick up CLI upgrades and fresh
    /// network connections without giving up the warm process on every edit.
    private static let maximumClientAge: TimeInterval = 60 * 60

    private let makeClient: ClientFactory
    private var client: Client?
    private var clientStartedAt: TimeInterval?
    private var config: CopilotACPConfig?
    private var warmSessionID: String?
    private var activeUses: [ObjectIdentifier: Int] = [:]
    private var retiredClients: [ObjectIdentifier: Client] = [:]
    /// In-flight client launch, shared by concurrent callers so only one
    /// `copilot --acp` process is ever started per config.
    private var starting: (
        id: UInt, config: CopilotACPConfig, startedAt: TimeInterval,
        task: Task<Client, Error>
    )?
    private var nextStartID: UInt = 0

    init(
        makeClient: @escaping ClientFactory = { config in
            try await CopilotACPClient(config: config)
        }
    ) {
        self.makeClient = makeClient
    }

    func prepare(
        config newConfig: CopilotACPConfig,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async {
        _ = try? await warmSession(config: newConfig, now: now)
    }

    func complete(
        _ prompt: String, config newConfig: CopilotACPConfig,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async throws -> String {
        let leasedClient = try await acquireClient(config: newConfig, now: now)
        do {
            let sessionID: String
            if let warmSessionID {
                sessionID = warmSessionID
                self.warmSessionID = nil
            } else {
                sessionID = try await leasedClient.newSession()
            }
            let output = try await leasedClient.prompt(sessionID: sessionID, text: prompt)
            await releaseClient(leasedClient)
            return output
        } catch {
            await releaseClient(leasedClient)
            await reset(config: newConfig, ifCurrent: leasedClient)
            throw error
        }
    }

    /// The live model list the CLI advertises. Reuses (or warms) the idle
    /// session rather than consuming it, so asking costs nothing extra.
    func availableModels(
        config newConfig: CopilotACPConfig,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async -> [CopilotModel] {
        do {
            _ = try await warmSession(config: newConfig, now: now)
            let leasedClient = try await acquireClient(config: newConfig, now: now)
            let models = await leasedClient.availableModels()
            await releaseClient(leasedClient)
            return models
        } catch {
            return []
        }
    }

    private func warmSession(config newConfig: CopilotACPConfig, now: TimeInterval) async throws -> String {
        if let warmSessionID, config == newConfig, !clientHasExpired(at: now) {
            return warmSessionID
        }
        let leasedClient = try await acquireClient(config: newConfig, now: now)
        do {
            let sessionID = try await leasedClient.newSession()
            guard config == newConfig, isCurrent(leasedClient) else {
                throw ProviderError.launchFailed("Copilot ACP configuration changed.")
            }
            warmSessionID = sessionID
            await releaseClient(leasedClient)
            return sessionID
        } catch {
            await releaseClient(leasedClient)
            await reset(config: newConfig, ifCurrent: leasedClient)
            throw error
        }
    }

    private func acquireClient(config newConfig: CopilotACPConfig, now: TimeInterval) async throws -> Client {
        let client = try await client(config: newConfig, now: now)
        let id = ObjectIdentifier(client)
        activeUses[id, default: 0] += 1
        return client
    }

    private func releaseClient(_ client: Client) async {
        let id = ObjectIdentifier(client)
        guard let count = activeUses[id] else { return }
        if count > 1 {
            activeUses[id] = count - 1
            return
        }
        activeUses[id] = nil
        if retiredClients.removeValue(forKey: id) != nil {
            await client.stop()
        }
    }

    private func retireClient(_ client: Client) async {
        let id = ObjectIdentifier(client)
        if activeUses[id, default: 0] > 0 {
            retiredClients[id] = client
        } else {
            await client.stop()
        }
    }

    /// The client for `newConfig`, launching one if needed.
    ///
    /// Actor isolation does not prevent reentrancy: every `await` here is a
    /// suspension point another caller can interleave at. In-flight creation is
    /// shared, and retired clients stay alive until their active calls finish.
    private func client(
        config newConfig: CopilotACPConfig, now: TimeInterval
    ) async throws -> Client {
        if let client, config == newConfig, !clientHasExpired(at: now) { return client }
        if let starting, starting.config == newConfig {
            let created = try await starting.task.value
            if let current = client, config == newConfig, !clientHasExpired(at: now) {
                if !sameClient(current, created) { await retireClient(created) }
                return current
            }
            guard config == newConfig, self.starting?.id == starting.id else {
                await retireClient(created)
                throw ProviderError.launchFailed("Copilot ACP configuration changed.")
            }
            self.starting = nil
            client = created
            clientStartedAt = starting.startedAt
            return created
        }

        let stale = client
        starting?.task.cancel()
        client = nil
        clientStartedAt = nil
        warmSessionID = nil
        config = newConfig
        nextStartID &+= 1
        let startID = nextStartID
        let startedAt = now
        let makeClient = self.makeClient
        let task = Task { try await makeClient(newConfig) }
        starting = (startID, newConfig, startedAt, task)
        if let stale { await retireClient(stale) }

        do {
            let created = try await task.value
            if let current = client, config == newConfig, !clientHasExpired(at: now) {
                if !sameClient(current, created) { await retireClient(created) }
                return current
            }
            guard config == newConfig, starting?.id == startID else {
                await retireClient(created)
                throw ProviderError.launchFailed("Copilot ACP configuration changed.")
            }
            starting = nil
            client = created
            clientStartedAt = startedAt
            return created
        } catch {
            if starting?.id == startID {
                starting = nil
                config = nil
            }
            throw error
        }
    }

    private func clientHasExpired(at now: TimeInterval) -> Bool {
        guard let clientStartedAt else { return false }
        return now - clientStartedAt >= Self.maximumClientAge
    }

    private func isCurrent(_ candidate: Client) -> Bool {
        guard let client else { return false }
        return sameClient(client, candidate)
    }

    private func sameClient(_ lhs: Client, _ rhs: Client) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    private func reset(config expectedConfig: CopilotACPConfig, ifCurrent expectedClient: Client) async {
        guard config == expectedConfig, isCurrent(expectedClient) else { return }
        starting?.task.cancel()
        starting = nil
        warmSessionID = nil
        config = nil
        clientStartedAt = nil
        client = nil
        await retireClient(expectedClient)
    }
}
