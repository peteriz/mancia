protocol CopilotACPClientProtocol: Actor {
    func newSession() async throws -> String
    func availableModels() -> [CopilotModel]
    func prompt(sessionID: String, text: String) async throws -> String
    func stop() async
}
