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
    let displayName = "GitHub Copilot CLI"

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Command construction (unit-tested)

    /// Directories that commonly hold a `copilot` binary, in priority order.
    /// These cover Homebrew (Apple Silicon + Intel), a manual `~/.local/bin`
    /// install, and the default npm global prefixes used by npm/nvm/Volta —
    /// none of which are reliably on a `.app` bundle's inherited `PATH` when
    /// launched from Finder or as a login item.
    static func searchDirectories() -> [String] {
        let home = NSHomeDirectory()
        var dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.local/bin",
            home + "/.npm-global/bin",
            home + "/.volta/bin",
            "/usr/bin",
        ]
        // Every Node version installed via nvm keeps its own bin directory.
        let nvmVersions = home + "/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            dirs += entries.sorted().reversed().map { "\(nvmVersions)/\($0)/bin" }
        }
        return dirs
    }

    /// Standard search locations for the `copilot` binary, in priority order.
    static func searchPaths() -> [String] {
        searchDirectories().map { $0 + "/copilot" }
    }

    /// True when `path` points at a runnable regular file (not a directory or a
    /// broken symlink), so a misconfigured override can't be selected and then
    /// fail at launch.
    static func isRunnableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Resolve the executable to run. Returns the binary path when found, or the
    /// `/usr/bin/env` fallback (which then runs `copilot` off `PATH`).
    static func resolveExecutable(
        override: String?,
        fileExists: (String) -> Bool = { isRunnableFile($0) }
    ) -> String {
        if let override, !override.isEmpty, fileExists(override) { return override }
        for candidate in searchPaths() where fileExists(candidate) { return candidate }
        return "/usr/bin/env"
    }

    /// A `PATH` value augmented with the standard install directories, so the
    /// `/usr/bin/env` fallback (and any child copilot spawns) can find the
    /// binary even under the minimal `PATH` a `.app` inherits from Finder.
    static func augmentedPath(base: String?) -> String {
        var seen = Set<String>()
        var dirs: [String] = []
        for dir in searchDirectories() + (base?.split(separator: ":").map(String.init) ?? []) {
            if !dir.isEmpty, seen.insert(dir).inserted { dirs.append(dir) }
        }
        return dirs.joined(separator: ":")
    }

    /// Build the full argv for a prompt. When the executable is the `env`
    /// fallback, `copilot` is prepended as the first argument.
    static func arguments(executable: String, prompt: String, model: String, reasoningEffort: String = "") -> [String] {
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
        let trimmedEffort = reasoningEffort.trimmingCharacters(in: .whitespaces)
        if !trimmedEffort.isEmpty { args += ["--reasoning-effort", trimmedEffort] }
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

    private func config() async -> (path: String, model: String, reasoningEffort: String) {
        await MainActor.run { (self.settings.copilotPath, self.settings.copilotModel, self.settings.reasoningEffort) }
    }

    func complete(_ prompt: String) async throws -> String {
        let (path, model, reasoningEffort) = await config()
        let executable = Self.resolveExecutable(override: path.isEmpty ? nil : path)
        let args = Self.arguments(executable: executable, prompt: prompt, model: model, reasoningEffort: reasoningEffort)

        let result: ProcessResult
        do {
            result = try await Self.runProcess(executable: executable, arguments: args, timeout: 90)
        } catch let error as ProviderError {
            throw error
        }

        let combined = result.stdout + "\n" + result.stderr
        if Self.looksMissingBinary(exitCode: result.exitCode, text: combined) {
            throw ProviderError.notFound
        }
        if Self.looksUnauthenticated(combined) { throw ProviderError.notAuthenticated }

        guard result.exitCode == 0 else {
            throw ProviderError.nonZeroExit(result.exitCode, Self.tail(of: combined))
        }

        let output = Self.postProcess(result.stdout)
        guard !output.isEmpty else { throw ProviderError.emptyOutput }
        return output
    }

    func checkAvailability() async -> ProviderStatus {
        let (path, _, _) = await config()
        let executable = Self.resolveExecutable(override: path.isEmpty ? nil : path)
        var args: [String] = []
        if executable == "/usr/bin/env" { args.append("copilot") }
        args.append("--version")
        do {
            let result = try await Self.runProcess(executable: executable, arguments: args, timeout: 10)
            if result.exitCode == 0 { return .ready }
            let combined = result.stdout + result.stderr
            if Self.looksMissingBinary(exitCode: result.exitCode, text: combined) { return .notFound }
            if Self.looksUnauthenticated(combined) { return .error("Not signed in") }
            return .error(Self.tail(of: combined))
        } catch ProviderError.launchFailed {
            return .notFound
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func looksUnauthenticated(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let needles = [
            "not logged in", "not authenticated", "not signed in",
            "please sign in", "please log in", "run `copilot`",
            "unauthorized", "authentication failed", "authentication required",
            "authentication expired", "no valid credentials", "sign in to",
            "/login", "copilot auth",
        ]
        return needles.contains { lowered.contains($0) }
    }

    /// Detects the shell/`env` "command not found" signal — exit code 127 with a
    /// no-such-file / command-not-found message. This is how the `/usr/bin/env`
    /// fallback reports that the `copilot` binary is not installed or not on
    /// `PATH`, as distinct from a genuine error returned by copilot itself.
    static func looksMissingBinary(exitCode: Int32, text: String) -> Bool {
        guard exitCode == 127 else { return false }
        let lowered = text.lowercased()
        return lowered.contains("no such file or directory")
            || lowered.contains("command not found")
            || lowered.contains("not found")
    }

    private static func tail(of text: String, lines: Int = 8) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return split.suffix(lines).joined(separator: "\n")
    }

    private static func runProcess(executable: String, arguments: [String], timeout: Double) async throws -> ProcessResult {
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mancia-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(base: environment["PATH"])

        let runner = ProcessRunner()
        return try await runner.run(
            executable: executable, arguments: arguments,
            environment: environment, workingDir: workDir, timeout: timeout
        )
    }
}

/// Owns a single `Process` and bridges its blocking API to async with timeout
/// and cancellation. All `Process` access is confined here, hence `@unchecked`.
private final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    func run(executable: String, arguments: [String], environment: [String: String], workingDir: URL, timeout: Double) async throws -> ProcessResult {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
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
        // Drain stdout and stderr concurrently. Reading one to completion before
        // the other risks a deadlock: if the unread pipe fills its buffer the
        // child blocks on write, and we block forever on the first read.
        let errData = readInBackground(errHandle)
        let outData = outHandle.readDataToEndOfFile()
        let collectedErr = errData.take()
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: decode(outData),
            stderr: decode(collectedErr)
        )
    }

    /// Lossily decode process output as UTF-8; never drop bytes to nil so that
    /// error tails and diagnostics survive non-UTF-8 sequences.
    private func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Read a file handle to EOF on a background thread, returning a box the
    /// caller blocks on once its own read has completed.
    private func readInBackground(_ handle: FileHandle) -> DataBox {
        let box = DataBox()
        Thread.detachNewThread {
            let data = handle.readDataToEndOfFile()
            box.set(data)
        }
        return box
    }

    /// Send SIGTERM, then escalate to SIGKILL shortly after so a child that
    /// ignores SIGTERM (or a stuck grandchild holding the pipes) can't wedge us.
    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// A thread-safe one-shot box used to hand background-read data back to the
/// reader thread.
private final class DataBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var data = Data()

    func set(_ value: Data) {
        data = value
        semaphore.signal()
    }

    func take() -> Data {
        semaphore.wait()
        return data
    }
}
