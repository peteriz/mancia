import Foundation
import SQLite3

/// A Copilot model as cached by the Copilot CLI.
struct CopilotModel: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var supportedReasoningEfforts: [String]?
}

/// Reads the model list the Copilot CLI caches in `~/.copilot/data.db`
/// (`app_state` table, key `copilot-available-models`). Read-only; falls back
/// to a minimal list when the database or key is unreadable.
enum CopilotModelCatalog {
    static let defaultDBPath = NSHomeDirectory() + "/.copilot/data.db"

    /// All reasoning-effort levels the CLI accepts for `--reasoning-effort`.
    static let allReasoningEfforts = ["none", "low", "medium", "high", "xhigh", "max"]

    /// Load the cached models, or nil when the cache is unreadable.
    static func loadModels(dbPath: String = defaultDBPath) -> [CopilotModel]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM app_state WHERE key = 'copilot-available-models' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return decode(String(cString: text))
    }

    /// Decode the cached JSON array (unit-tested without touching SQLite).
    static func decode(_ json: String) -> [CopilotModel]? {
        let models = try? JSONDecoder().decode([CopilotModel].self, from: Data(json.utf8))
        return (models?.isEmpty == false) ? models : nil
    }

    /// Models for the settings picker: the cache when readable, else a minimal
    /// fallback of "auto" plus whatever model string is currently stored.
    static func modelsForPicker(storedModel: String, dbPath: String = defaultDBPath) -> [CopilotModel] {
        var models = loadModels(dbPath: dbPath) ?? [CopilotModel(id: "auto", name: "Auto")]
        let stored = storedModel.trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty, !models.contains(where: { $0.id == stored }) {
            models.append(CopilotModel(id: stored, name: stored))
        }
        return models
    }
}
