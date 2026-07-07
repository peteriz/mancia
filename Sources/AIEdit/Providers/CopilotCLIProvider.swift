import Foundation

/// Errors surfaced by the Copilot provider, each with actionable guidance.
enum ProviderError: LocalizedError, Equatable {
    case notFound
    case notAuthenticated
    case launchFailed(String)
    case timedOut
    case nonZeroExit(Int32, String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "GitHub Copilot CLI was not found. Install it with `npm install -g @github/copilot`, or set the path in Settings."
        case .notAuthenticated:
            return "GitHub Copilot is not signed in. Run `copilot` once in a terminal to authenticate."
        case .launchFailed(let message):
            return "Could not launch Copilot CLI: \(message)"
        case .timedOut:
            return "Copilot timed out after 90 seconds."
        case .nonZeroExit(let code, let tail):
            return "Copilot failed (exit \(code)).\n\(tail)"
        case .emptyOutput:
            return "Copilot returned no output."
        }
    }
}

private struct ProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// LLM provider backed by the GitHub Copilot CLI in non-interactive mode.
final class CopilotCLIProvider: LLMProvider {
    let id = "copilot-cli"
    let displayName = "GitHub Copilot CLI"

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Command construction (unit-tested)

    /// Standard search locations, in priority order.
    static func searchPaths() -> [String] {
        [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
            NSHomeDirectory() + "/.local/bin/copilot",
        ]
    }

    /// Resolve the executable to run. Returns the binary path when found, or the
    /// `/usr/bin/env` fallback (which then runs `copilot` off `PATH`).
    static func resolveExecutable(
        override: String?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if let override, !override.isEmpty, fileExists(override) { return override }
        for candidate in searchPaths() where fileExists(candidate) { return candidate }
        return "/usr/bin/env"
    }

    /// Build the full argv for a prompt. When the executable is the `env`
    /// fallback, `copilot` is prepended as the first argument.
    static func arguments(executable: String, prompt: String, model: String) -> [String] {
        var args: [String] = []
        if executable == "/usr/bin/env" { args.append("copilot") }
        args += [
            "-p", prompt,
            "-s",
            "--no-color",
            "--no-custom-instructions",
            "--available-tools=",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        if !trimmedModel.isEmpty { args += ["--model", trimmedModel] }
        return args
    }

    /// Trim surrounding whitespace and strip a single wrapping code-fence pair.
    static func postProcess(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```"), let firstNewline = text.firstIndex(of: "\n") else { return text }
        let body = text[text.index(after: firstNewline)...]
        guard let closing = body.range(of: "```", options: .backwards) else { return text }
        text = String(body[..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    // MARK: - LLMProvider

    private func config() async -> (path: String, model: String) {
        await MainActor.run { (self.settings.copilotPath, self.settings.copilotModel) }
    }

    func complete(_ prompt: String) async throws -> String {
        let (path, model) = await config()
        let executable = Self.resolveExecutable(override: path.isEmpty ? nil : path)
        let args = Self.arguments(executable: executable, prompt: prompt, model: model)

        let result: ProcessResult
        do {
            result = try await Self.runProcess(executable: executable, arguments: args, timeout: 90)
        } catch let error as ProviderError {
            throw error
        }

        let combined = result.stdout + "\n" + result.stderr
        if Self.looksUnauthenticated(combined) { throw ProviderError.notAuthenticated }

        guard result.exitCode == 0 else {
            throw ProviderError.nonZeroExit(result.exitCode, Self.tail(of: combined))
        }

        let output = Self.postProcess(result.stdout)
        guard !output.isEmpty else { throw ProviderError.emptyOutput }
        return output
    }

    func checkAvailability() async -> ProviderStatus {
        let (path, _) = await config()
        let executable = Self.resolveExecutable(override: path.isEmpty ? nil : path)
        var args: [String] = []
        if executable == "/usr/bin/env" { args.append("copilot") }
        args.append("--version")
        do {
            let result = try await Self.runProcess(executable: executable, arguments: args, timeout: 10)
            if result.exitCode == 0 { return .ready }
            if Self.looksUnauthenticated(result.stdout + result.stderr) { return .error("Not signed in") }
            return .error(Self.tail(of: result.stdout + result.stderr))
        } catch ProviderError.launchFailed {
            return .notFound
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func looksUnauthenticated(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("not logged in") || lowered.contains("not authenticated")
            || lowered.contains("please sign in") || lowered.contains("run `copilot`")
    }

    private static func tail(of text: String, lines: Int = 8) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return split.suffix(lines).joined(separator: "\n")
    }

    private static func runProcess(executable: String, arguments: [String], timeout: Double) async throws -> ProcessResult {
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-edit-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let runner = ProcessRunner()
        return try await runner.run(executable: executable, arguments: arguments, workingDir: workDir, timeout: timeout)
    }
}

/// Owns a single `Process` and bridges its blocking API to async with timeout
/// and cancellation. All `Process` access is confined here, hence `@unchecked`.
private final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    func run(executable: String, arguments: [String], workingDir: URL, timeout: Double) async throws -> ProcessResult {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDir
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
                group.addTask { try self.runBlocking() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.terminate()
                    return nil
                }
                defer { group.cancelAll() }
                while let result = try await group.next() {
                    if let result { return result }
                    throw ProviderError.timedOut
                }
                throw ProviderError.timedOut
            }
        } onCancel: {
            self.terminate()
        }
    }

    private func runBlocking() throws -> ProcessResult {
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        do {
            try process.run()
        } catch {
            throw ProviderError.launchFailed(error.localizedDescription)
        }
        let outData = outHandle.readDataToEndOfFile()
        let errData = errHandle.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }
}
