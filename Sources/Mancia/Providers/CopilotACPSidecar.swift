/// Keeps one Copilot ACP process alive and one empty session warm.
///
/// The warm session is single-use: once a prompt is sent, the session id is
/// discarded so selected text never carries into a later edit.
actor CopilotACPSidecar {
    private var client: CopilotACPClient?
    private var config: CopilotACPConfig?
    private var warmSessionID: String?

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

    private func warmSession(config newConfig: CopilotACPConfig) async throws -> String {
        if let warmSessionID, config == newConfig { return warmSessionID }
        let client = try await client(config: newConfig)
        let sessionID = try await client.newSession()
        warmSessionID = sessionID
        return sessionID
    }

    private func client(config newConfig: CopilotACPConfig) async throws -> CopilotACPClient {
        if let client, config == newConfig { return client }
        await reset()
        let client = try await CopilotACPClient(config: newConfig)
        self.client = client
        self.config = newConfig
        return client
    }

    private func reset() async {
        warmSessionID = nil
        config = nil
        if let client {
            await client.stop()
            self.client = nil
        }
    }
}
