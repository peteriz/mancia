import Foundation
import SQLite3

/// A Copilot model as cached by the Copilot CLI.
struct CopilotModel: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var supportedReasoningEfforts: [String]?
    /// Latency/capability class the Copilot model picker sorts by:
    /// "lightweight" (fastest), "versatile", or "powerful" (slowest). Missing
    /// or unrecognized for the special "auto" entry.
    var modelPickerCategory: String?
    /// Relative cost class: "low", "medium", or "high".
    var modelPickerPriceCategory: String?
}

/// A named group of models, fastest-to-slowest, for the settings picker.
struct ModelTier: Identifiable, Equatable {
    let id: String
    let title: String
    let models: [CopilotModel]
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

        // The copilot CLI may be writing this DB concurrently; wait briefly for
        // any lock rather than failing (or blocking) indefinitely.
        sqlite3_busy_timeout(db, 500)

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
        guard let models = try? JSONDecoder().decode([CopilotModel].self, from: Data(json.utf8)) else {
            return nil
        }
        // Drop malformed and duplicate entries so the settings picker can't bind
        // to an empty name or render two rows with the same tag.
        var seen = Set<String>()
        let cleaned = models.filter { model in
            guard !model.id.isEmpty, !model.name.isEmpty else { return false }
            return seen.insert(model.id).inserted
        }
        return cleaned.isEmpty ? nil : cleaned
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

    /// Title of the latency tier a `modelPickerCategory` maps to, fastest
    /// first. Unknown or missing categories land in the middle ("Balanced")
    /// tier rather than being dropped, so a model the cache doesn't classify
    /// still shows up somewhere in the picker.
    private static func tierTitle(for category: String?) -> String {
        switch category {
        case "lightweight": return "Fastest"
        case "powerful": return "Most capable"
        default: return "Balanced"
        }
    }

    /// Sort key for `modelPickerPriceCategory`: low < medium < high < unknown.
    private static func priceRank(_ price: String?) -> Int {
        switch price {
        case "low": return 0
        case "medium": return 1
        case "high": return 2
        default: return 3
        }
    }

    /// Group models into latency tiers, fastest to slowest, for the settings
    /// picker. The special "auto" entry (id "auto", no category) is excluded —
    /// it is the picker's separate "Default (auto)" row. Within a tier, models
    /// sort by price category (low, medium, high) then by display name.
    static func tiered(_ models: [CopilotModel]) -> [ModelTier] {
        let order = ["Fastest", "Balanced", "Most capable"]
        var byTitle: [String: [CopilotModel]] = [:]
        for model in models where model.id != "auto" {
            byTitle[tierTitle(for: model.modelPickerCategory), default: []].append(model)
        }
        return order.compactMap { title in
            guard let group = byTitle[title], !group.isEmpty else { return nil }
            let sorted = group.sorted { a, b in
                let ranks = (priceRank(a.modelPickerPriceCategory), priceRank(b.modelPickerPriceCategory))
                if ranks.0 != ranks.1 { return ranks.0 < ranks.1 }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ModelTier(id: title, title: title, models: sorted)
        }
    }

    /// Preferred order of ultra-fast lightweight models, measured by wall-clock
    /// latency through the real Copilot CLI pipeline (see docs/ARCHITECTURE.md
    /// or the task history for the benchmark). `gpt-5.4-mini` (paired with
    /// `reasoningEffort: "none"`) was the fastest of the four lightweight
    /// models available at benchmark time, roughly half the latency of the
    /// runners-up.
    static let preferredFastModelIDs = ["gpt-5.4-mini", "claude-haiku-4.5", "gemini-3.5-flash", "gpt-5-mini"]

    /// The recommended ultra-fast default: the first preferred id present in
    /// the catalog, else the first model in the fastest tier, else nil when
    /// the catalog has no lightweight models at all (or is empty).
    static func recommendedFastModel(from models: [CopilotModel]) -> String? {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        for id in preferredFastModelIDs where byID[id] != nil {
            return id
        }
        return tiered(models).first { $0.title == "Fastest" }?.models.first?.id
    }
}
