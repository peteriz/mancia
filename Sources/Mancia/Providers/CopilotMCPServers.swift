import Foundation

/// The MCP servers the user's Copilot CLI would load, so Mancia can disable
/// every one of them by name.
///
/// Edits need no tools. `--available-tools=` hides tools from one-shot runs,
/// but ACP sessions still load every configured server's tool definitions; a
/// large one (hundreds of tools) overflows the model's context and every turn
/// fails with "Static system messages and tool definitions exceed the model's
/// usable context budget". No CLI flag skips user servers wholesale, so each
/// is passed to `--disable-mcp-server`.
actor CopilotMCPServers {
    private static let maximumAge: TimeInterval = 5 * 60

    private var cached: (executable: String, names: [String], at: TimeInterval)?

    func names(
        executable: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async -> [String] {
        if let cached, cached.executable == executable, now - cached.at < Self.maximumAge {
            return cached.names
        }
        let names = await CopilotCLIProvider.listMCPServerNames(executable: executable)
        cached = (executable, names, now)
        return names
    }

    /// Server names from `copilot mcp list --json`, sorted so equal lists
    /// compare equal. Unparseable output yields no names.
    static func names(fromListJSON output: String) -> [String] {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any]
        else { return [] }
        return servers.keys.sorted()
    }
}
