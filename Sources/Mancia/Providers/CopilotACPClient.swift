import Foundation

struct CopilotACPConfig: Equatable {
    let executable: String
    let model: String
    let reasoningEffort: String
}

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
        let client = try await client(config: newConfig)
        let sessionID: String
        if let warmSessionID {
            sessionID = warmSessionID
            self.warmSessionID = nil
        } else {
            sessionID = try await client.newSession()
        }
        do {
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

/// Minimal ACP JSON-RPC client for Copilot CLI.
actor CopilotACPClient {
    private let process: Process
    private let input: FileHandle
    private let workingDir: URL
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var chunksBySession: [String: String] = [:]

    init(config: CopilotACPConfig) async throws {
        workingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mancia-acp-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CopilotCLIProvider.augmentedPath(base: environment["PATH"])

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = CopilotCLIProvider.acpArguments(
            executable: config.executable,
            model: config.model,
            reasoningEffort: config.reasoningEffort
        )
        process.environment = environment
        process.currentDirectoryURL = workingDir
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: workingDir)
            throw ProviderError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.input = inPipe.fileHandleForWriting
        readLines(from: outPipe.fileHandleForReading)
        drain(errPipe.fileHandleForReading)

        do {
            _ = try await request(
                method: "initialize",
                params: ["protocolVersion": 1, "clientCapabilities": [:]],
                timeout: 10
            )
        } catch {
            input.closeFile()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: workingDir)
            throw error
        }
    }

    func newSession() async throws -> String {
        let line = try await request(
            method: "session/new",
            params: ["cwd": workingDir.path, "mcpServers": []],
            timeout: 15
        )
        guard let result = field("result", in: line) as? [String: Any],
              let sessionID = result["sessionId"] as? String else {
            throw ProviderError.emptyOutput
        }
        return sessionID
    }

    func prompt(sessionID: String, text: String) async throws -> String {
        chunksBySession[sessionID] = ""
        let line = try await request(
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]],
            ],
            timeout: 90
        )
        let stopReason = (field("result", in: line) as? [String: Any])?["stopReason"] as? String
        guard stopReason == nil || stopReason == "end_turn" else {
            throw ProviderError.nonZeroExit(1, "Copilot stopped with \(stopReason ?? "unknown reason").")
        }
        let output = chunksBySession.removeValue(forKey: sessionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { throw ProviderError.emptyOutput }
        return output
    }

    func stop() {
        input.closeFile()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: workingDir)
    }

    private func request(method: String, params: [String: Any], timeout: Double) async throws -> String {
        let id = nextID
        nextID += 1
        let data = try jsonData(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                input.write(data)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.failPending(id, with: ProviderError.timedOut)
                }
            }
        } onCancel: {
            Task { await self.failPending(id, with: CancellationError()) }
        }
    }

    private func handle(line: String) {
        guard let object = jsonObject(line) else { return }
        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: ProviderError.nonZeroExit(1, String(describing: error)))
            } else {
                continuation.resume(returning: line)
            }
            return
        }
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return }
        if method == "session/update" {
            appendChunk(from: params)
        } else if method == "session/request_permission", let id = object["id"] as? Int {
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["outcome": ["outcome": "cancelled"]],
            ]
            if let data = try? jsonData(response) { input.write(data) }
        }
    }

    private func appendChunk(from params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String,
              var current = chunksBySession[sessionID],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String else { return }
        current += text
        chunksBySession[sessionID] = current
    }

    private func failPending(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handleEOF() {
        let error = ProviderError.launchFailed("Copilot ACP process exited.")
        for id in pending.keys {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func readLines(from handle: FileHandle) {
        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let lineData = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                    await self?.handle(line: line)
                }
            }
            await self?.handleEOF()
        }
    }

    private func drain(_ handle: FileHandle) {
        Task.detached {
            while !handle.availableData.isEmpty {}
        }
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func field(_ name: String, in line: String) -> Any? {
        jsonObject(line)?[name]
    }
}
