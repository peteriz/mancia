/// Keeps one Copilot ACP process alive and one empty session warm.
///
/// The warm session is single-use: once a prompt is sent, the session id is
/// discarded so selected text never carries into a later edit.
actor CopilotACPSidecar {
    private var client: CopilotACPClient?
    private var config: CopilotACPConfig?
    private var warmSessionID: String?
    /// In-flight client launch, shared by concurrent callers so only one
    /// `copilot --acp` process is ever started per config.
    private var starting: Task<CopilotACPClient, Error>?

    func prepare(config newConfig: CopilotACPConfig) async {
        do {
            _ = try await warmSession(config: newConfig)
        } catch {
            await reset()
        }
    }

    func complete(_ prompt: String, config newConfig: CopilotACPConfig) async throws -> String {
        do {
            let client = try await client(config: newConfig)
            let sessionID: String
            if let warmSessionID {
                sessionID = warmSessionID
                self.warmSessionID = nil
            } else {
                sessionID = try await client.newSession()
            }
            return try await client.prompt(sessionID: sessionID, text: prompt)
        } catch {
            await reset()
            throw error
        }
    }

    /// The live model list the CLI advertises. Reuses (or warms) the idle
    /// session rather than consuming it, so asking costs nothing extra.
    func availableModels(config newConfig: CopilotACPConfig) async -> [CopilotModel] {
        do {
            _ = try await warmSession(config: newConfig)
            return await client?.availableModels() ?? []
        } catch {
            await reset()
            return []
        }
    }

    private func warmSession(config newConfig: CopilotACPConfig) async throws -> String {
        if let warmSessionID, config == newConfig { return warmSessionID }
        let client = try await client(config: newConfig)
        let sessionID = try await client.newSession()
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
    private func client(config newConfig: CopilotACPConfig) async throws -> CopilotACPClient {
        if let client, config == newConfig { return client }
        if let starting, config == newConfig { return try await starting.value }

        let stale = client
        client = nil
        warmSessionID = nil
        config = newConfig
        let task = Task {
            // Tear the old process down inside the task so the state above is
            // already published before this first suspends.
            if let stale { await stale.stop() }
            return try await CopilotACPClient(config: newConfig)
        }
        starting = task
        defer { starting = nil }
        do {
            let created = try await task.value
            client = created
            return created
        } catch {
            config = nil
            throw error
        }
    }

    private func reset() async {
        starting?.cancel()
        starting = nil
        warmSessionID = nil
        config = nil
        if let client {
            await client.stop()
            self.client = nil
        }
    }
}
