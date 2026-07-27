import Foundation
import SQLite3

/// A Copilot model as cached by the Copilot CLI.
struct CopilotModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var supportedReasoningEfforts: [String]?
    /// Latency/capability class the Copilot model picker sorts by:
    /// "lightweight" (fastest), "versatile", or "powerful" (slowest). Missing
    /// or unrecognized for the special "auto" entry.
    var modelPickerCategory: String?
    /// Relative cost class: "low", "medium", or "high".
    var modelPickerPriceCategory: String?
    /// Premium-request multiplier the live listing reports (`"0.33x"` → 0.33).
    /// Absent from the on-disk cache, which carries no cost field at all. It is
    /// the only fine-grained, self-updating weight signal available, so the
    /// picker's recommendation ranks on it.
    var usageMultiplier: Double?
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

    /// Reasoning-effort levels the CLI accepts for `--reasoning-effort`, in
    /// increasing order of effort. Only a floor — see `reasoningEfforts(in:)`.
    static let allReasoningEfforts = ["none", "low", "medium", "high", "xhigh", "max"]

    /// Effort levels to offer for a catalog: the known levels above, plus any
    /// the catalog itself advertises that we don't know about yet, so a level
    /// the CLI adds later still reaches the picker without a code change.
    /// Known levels keep their meaningful order; new ones are appended.
    static func reasoningEfforts(in models: [CopilotModel]) -> [String] {
        var levels = allReasoningEfforts
        for model in models {
            for level in model.supportedReasoningEfforts ?? [] where !levels.contains(level) {
                levels.append(level)
            }
        }
        return levels
    }

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

    /// Combine the live ACP listing with the CLI's on-disk cache.
    ///
    /// The live list is authoritative for *which* models exist — it comes
    /// straight from the running CLI, while `~/.copilot/data.db` is only
    /// rewritten when the interactive Copilot TUI runs and so can be months
    /// stale (this is why newly released models went missing from the picker).
    /// The cache is still the only source of `modelPickerCategory` and
    /// `supportedReasoningEfforts`, so those are carried over by id.
    static func merged(live: [CopilotModel], cached: [CopilotModel]) -> [CopilotModel] {
        guard !live.isEmpty else { return cached }
        let cachedByID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return live.map { model in
            guard let match = cachedByID[model.id] else { return model }
            var merged = model
            merged.modelPickerCategory = model.modelPickerCategory ?? match.modelPickerCategory
            merged.supportedReasoningEfforts = model.supportedReasoningEfforts ?? match.supportedReasoningEfforts
            merged.modelPickerPriceCategory = model.modelPickerPriceCategory ?? match.modelPickerPriceCategory
            merged.usageMultiplier = model.usageMultiplier ?? match.usageMultiplier
            return merged
        }
    }

    /// The exact list the settings picker binds to: the live listing merged
    /// over the cache, with the stored selection kept even when the backend no
    /// longer offers it.
    ///
    /// A picker whose list omits its own bound value renders a blank selection,
    /// so a retired-but-selected model has to survive. The *cached* entry is
    /// reused when there is one so it keeps its tier and
    /// `supportedReasoningEfforts`; only a model nothing knows about falls back
    /// to a bare id-as-name row.
    ///
    /// Everything that renders or verifies the picker goes through here, so
    /// `--list-models` cannot drift from what Settings actually shows.
    static func pickerModels(live: [CopilotModel], cached: [CopilotModel], storedModel: String) -> [CopilotModel] {
        var models = merged(live: live, cached: cached)
        let stored = storedModel.trimmingCharacters(in: .whitespaces)
        guard !stored.isEmpty, !models.contains(where: { $0.id == stored }) else { return models }
        models.append(cached.first { $0.id == stored } ?? CopilotModel(id: stored, name: stored))
        return models
    }

    /// Title of the latency tier a `modelPickerCategory` maps to, fastest
    /// first. Models from the live ACP listing carry no category, so when it is
    /// unknown we fall back to the price class — high-cost models are the
    /// "powerful" ones, low-cost the lightweight ones. A model with neither
    /// signal lands in the middle ("Balanced") tier rather than being dropped,
    /// so it still shows up somewhere in the picker.
    private static func tierTitle(for category: String?, price: String? = nil) -> String {
        switch category {
        case "lightweight": return "Fastest"
        case "powerful": return "Most capable"
        case "versatile": return "Balanced"
        default: break
        }
        switch price {
        case "low": return "Fastest"
        case "high": return "Most capable"
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
    /// sort by price category (low, medium, high), then by the premium-request
    /// multiplier, then by display name.
    static func tiered(_ models: [CopilotModel]) -> [ModelTier] {
        let order = ["Fastest", "Balanced", "Most capable"]
        var byTitle: [String: [CopilotModel]] = [:]
        for model in models where model.id != "auto" {
            let title = tierTitle(for: model.modelPickerCategory, price: model.modelPickerPriceCategory)
            byTitle[title, default: []].append(model)
        }
        return order.compactMap { title in
            guard let group = byTitle[title], !group.isEmpty else { return nil }
            let sorted = group.sorted { a, b in
                let ranks = (priceRank(a.modelPickerPriceCategory), priceRank(b.modelPickerPriceCategory))
                if ranks.0 != ranks.1 { return ranks.0 < ranks.1 }
                let usage = (a.usageMultiplier ?? .greatestFiniteMagnitude, b.usageMultiplier ?? .greatestFiniteMagnitude)
                if usage.0 != usage.1 { return usage.0 < usage.1 }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ModelTier(id: title, title: title, models: sorted)
        }
    }

    /// The recommended low-latency default, derived entirely from what the
    /// backend advertises — no hardcoded model ids, so a newly released model
    /// can win the moment it appears and a retired one stops being suggested
    /// without any code change.
    ///
    /// Ranking, in order: Copilot's own latency class (the "Fastest" tier, i.e.
    /// `modelPickerCategory == "lightweight"` or a low price when the class is
    /// unknown), then the cheapest premium-request multiplier, then the cheaper
    /// price class, then name for a stable tie-break. Cost is a proxy for
    /// weight rather than a direct latency measurement, but within a single
    /// latency class the lighter model is the faster one, and unlike a
    /// benchmark table it stays correct on its own.
    ///
    /// Returns nil when the catalog has no fast-tier models at all (or is
    /// empty), leaving the model unset rather than guessing.
    static func recommendedFastModel(from models: [CopilotModel]) -> String? {
        tiered(models).first { $0.title == "Fastest" }?.models.min(by: fasterFirst)?.id
    }

    /// Ordering used to pick the recommendation: cheapest multiplier wins, then
    /// price class, then name. A model with no multiplier sorts after every
    /// model that has one, so an unranked entry never displaces a known-cheap
    /// one.
    private static func fasterFirst(_ a: CopilotModel, _ b: CopilotModel) -> Bool {
        let usage = (a.usageMultiplier ?? .greatestFiniteMagnitude, b.usageMultiplier ?? .greatestFiniteMagnitude)
        if usage.0 != usage.1 { return usage.0 < usage.1 }
        let prices = (priceRank(a.modelPickerPriceCategory), priceRank(b.modelPickerPriceCategory))
        if prices.0 != prices.1 { return prices.0 < prices.1 }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
