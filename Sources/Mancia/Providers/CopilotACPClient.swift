import Foundation

/// Minimal ACP JSON-RPC client for Copilot CLI.
actor CopilotACPClient {
    private let process: Process
    private let input: FileHandle
    private let workingDir: URL
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var chunksBySession: [String: String] = [:]
    /// Models advertised by the CLI in the most recent `session/new` reply.
    private var models: [CopilotModel] = []

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
        guard let sessionID = Self.sessionID(fromNewSessionResponse: line) else {
            throw ProviderError.emptyOutput
        }
        // The same reply carries the live model list; keep it so Settings can
        // show what the CLI actually offers today rather than a stale cache.
        let listed = Self.models(fromNewSessionResponse: line)
        if !listed.isEmpty { models = listed }
        return sessionID
    }

    /// The live model list from the most recent `session/new`, empty until one
    /// has been created.
    func availableModels() -> [CopilotModel] { models }

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
        let stopReason = Self.stopReason(fromPromptResponse: line)
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
        guard let object = Self.jsonObject(line) else { return }
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
        guard let chunk = Self.agentMessageChunk(from: params),
              var current = chunksBySession[chunk.sessionID] else { return }
        current += chunk.text
        chunksBySession[chunk.sessionID] = current
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

    static func sessionID(fromNewSessionResponse line: String) -> String? {
        guard let result = jsonObject(line)?["result"] as? [String: Any] else { return nil }
        return result["sessionId"] as? String
    }

    /// Parse `result.models.availableModels` out of a `session/new` reply.
    ///
    /// ACP reports the id/name plus a `_meta.copilotPriceCategory`, but no
    /// `modelPickerCategory` — see `CopilotModelCatalog.merged` for how the
    /// latency tier is recovered from the on-disk cache.
    static func models(fromNewSessionResponse line: String) -> [CopilotModel] {
        guard let result = jsonObject(line)?["result"] as? [String: Any],
              let models = result["models"] as? [String: Any],
              let available = models["availableModels"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return available.compactMap { entry in
            guard let id = entry["modelId"] as? String, !id.isEmpty,
                  let name = entry["name"] as? String, !name.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let meta = entry["_meta"] as? [String: Any]
            return CopilotModel(
                id: id,
                name: name,
                modelPickerPriceCategory: meta?["copilotPriceCategory"] as? String,
                usageMultiplier: usageMultiplier(meta?["copilotUsage"])
            )
        }
    }

    /// Parse the premium-request multiplier the listing reports as a string
    /// (`"0.33x"`, `"15x"`, `"0x"`). Returns nil for anything unparseable so a
    /// format change degrades to "unranked" rather than to a wrong number.
    static func usageMultiplier(_ raw: Any?) -> Double? {
        guard let text = raw as? String else { return raw as? Double }
        return Double(text.hasSuffix("x") ? String(text.dropLast()) : text)
    }

    static func stopReason(fromPromptResponse line: String) -> String? {
        (jsonObject(line)?["result"] as? [String: Any])?["stopReason"] as? String
    }

    static func agentMessageChunk(from params: [String: Any]) -> (sessionID: String, text: String)? {
        guard let sessionID = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String else { return nil }
        return (sessionID, text)
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
