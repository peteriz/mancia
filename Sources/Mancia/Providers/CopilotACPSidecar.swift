import Foundation

/// Keeps one Copilot ACP process alive and one empty session warm.
///
/// The warm session is single-use: once a prompt is sent, the session id is
/// discarded so selected text never carries into a later edit.
actor CopilotACPSidecar {
    /// A bounded lifetime lets the menu-bar app pick up CLI upgrades and fresh
    /// network connections without giving up the warm process on every edit.
    private static let maximumClientAge: TimeInterval = 60 * 60

    private var client: CopilotACPClient?
    private var clientStartedAt: TimeInterval?
    private var config: CopilotACPConfig?
    private var warmSessionID: String?
    /// In-flight client launch, shared by concurrent callers so only one
    /// `copilot --acp` process is ever started per config.
    private var starting: (
        id: UInt, config: CopilotACPConfig, startedAt: TimeInterval,
        task: Task<CopilotACPClient, Error>
    )?
    private var nextStartID: UInt = 0

    func prepare(
        config newConfig: CopilotACPConfig,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async {
        do {
            _ = try await warmSession(config: newConfig, now: now)
        } catch {
            await reset(config: newConfig)
        }
    }

    func complete(
        _ prompt: String, config newConfig: CopilotACPConfig,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async throws -> String {
        do {
            let client = try await client(config: newConfig, now: now)
            let sessionID: String
            if let warmSessionID {
                sessionID = warmSessionID
                self.warmSessionID = nil
            } else {
                sessionID = try await client.newSession()
            }
            return try await client.prompt(sessionID: sessionID, text: prompt)
        } catch {
            await reset(config: newConfig)
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
            return await client?.availableModels() ?? []
        } catch {
            await reset(config: newConfig)
            return []
        }
    }

    private func warmSession(config newConfig: CopilotACPConfig, now: TimeInterval) async throws -> String {
        if let warmSessionID, config == newConfig, !clientHasExpired(at: now) {
            return warmSessionID
        }
        let client = try await client(config: newConfig, now: now)
        let sessionID = try await client.newSession()
        guard config == newConfig, self.client === client else {
            throw ProviderError.launchFailed("Copilot ACP configuration changed.")
        }
        warmSessionID = sessionID
        return sessionID
    }

    /// The client for `newConfig`, launching one if needed.
    ///
    /// Actor isolation does not prevent reentrancy: every `await` here is a
    /// suspension point another caller can interleave at. Two callers arriving
    /// with no client stored — the panel warming while Settings asks for the
    /// model list, say — would each launch a `copilot --acp` process, and the
    /// second assignment would strand the first one running with nothing left
    /// to stop it. So in-flight creation is shared through a stored `Task`
    /// rather than repeated, and the check-then-store below runs with no
    /// `await` between the two, which is what makes it atomic.
    private func client(
        config newConfig: CopilotACPConfig, now: TimeInterval
    ) async throws -> CopilotACPClient {
        if let client, config == newConfig, !clientHasExpired(at: now) { return client }
        if let starting, starting.config == newConfig {
            let created = try await starting.task.value
            if let client, config == newConfig, !clientHasExpired(at: now) {
                if client !== created { await created.stop() }
                return client
            }
            guard config == newConfig, self.starting?.id == starting.id else {
                await created.stop()
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
        warmSessionID = nil
        config = newConfig
        nextStartID &+= 1
        let startID = nextStartID
        let startedAt = now
        let task = Task {
            // Tear the old process down inside the task so the state above is
            // already published before this first suspends.
            if let stale { await stale.stop() }
            return try await CopilotACPClient(config: newConfig)
        }
        starting = (startID, newConfig, startedAt, task)
        do {
            let created = try await task.value
            if let client, config == newConfig, !clientHasExpired(at: now) {
                if client !== created { await created.stop() }
                return client
            }
            guard config == newConfig, starting?.id == startID else {
                await created.stop()
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
        Self.isClientExpired(startedAt: clientStartedAt, now: now)
    }

    static func isClientExpired(startedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= maximumClientAge
    }

    private func reset(config expectedConfig: CopilotACPConfig) async {
        guard config == expectedConfig else { return }
        starting?.task.cancel()
        starting = nil
        warmSessionID = nil
        config = nil
        clientStartedAt = nil
        if let client {
            await client.stop()
            self.client = nil
        }
    }
}
