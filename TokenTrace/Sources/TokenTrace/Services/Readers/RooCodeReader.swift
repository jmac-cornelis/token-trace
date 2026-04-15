import Foundation
import SQLite3

// MARK: - RooCodeReader

final class RooCodeReader {

    // MARK: - Properties

    private let basePath: String

    static let defaultBasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"
    }()

    /// Path to the VS Code global state database that stores Roo Code API config metadata.
    private static let vscodeStatePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/globalStorage/state.vscdb"
    }()

    // MARK: - Cursor

    /// Cursor is JSON: `{"lastTimestamp": <epoch_ms>}`. Encodes the high-water mark for incremental reads.
    private struct CursorState: Codable {
        let lastTimestamp: Int64
    }

    // MARK: - Index File Types

    private struct TaskIndex: Decodable {
        let entries: [TaskEntry]
    }

    private struct TaskEntry: Decodable {
        let id: String
        let ts: Int64
        let task: String?
        let tokensIn: Int?
        let tokensOut: Int?
        let totalCost: Double?
        let workspace: String?
        let mode: String?
        let apiConfigName: String?
        let cacheWrites: Int?
        let cacheReads: Int?
        let status: String?
    }

    /// One entry from Roo Code's `listApiConfigMeta` stored in the VS Code state DB.
    private struct ApiConfigMeta: Decodable {
        let name: String
        let id: String
        let apiProvider: String?
        let modelId: String?
    }

    // MARK: - Initialization

    init(basePath: String = RooCodeReader.defaultBasePath) {
        self.basePath = basePath
    }

    // MARK: - API Config → Model ID Mapping

    /// Reads the VS Code global state database and returns a mapping from
    /// Roo Code `apiConfigName` (e.g. "cornelis") to the actual model ID
    /// (e.g. "developer-opus-extended").
    ///
    /// Roo Code stores this mapping in `listApiConfigMeta` inside the
    /// `RooVeterinaryInc.roo-cline` key of the VS Code state.vscdb SQLite file.
    /// We open the DB read-only with SQLite3 directly to avoid a GRDB dependency
    /// in this reader.
    private func loadApiConfigModelMap() -> [String: String] {
        let dbPath = RooCodeReader.vscodeStatePath
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        var db: OpaquePointer?
        // Open read-only; if it fails, return empty map and fall back to apiConfigName.
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'RooVeterinaryInc.roo-cline'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let rawBytes = sqlite3_column_text(stmt, 0) else { return [:] }

        let jsonString = String(cString: rawBytes)
        guard let jsonData = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let metaArray = root["listApiConfigMeta"] as? [[String: Any]] else {
            return [:]
        }

        guard let metaData = try? JSONSerialization.data(withJSONObject: metaArray),
              let configs = try? JSONDecoder().decode([ApiConfigMeta].self, from: metaData) else {
            return [:]
        }

        // Build name → modelId map; skip entries without a modelId.
        var map: [String: String] = [:]
        for config in configs {
            if let modelId = config.modelId, !modelId.isEmpty {
                map[config.name] = modelId
            }
        }
        return map
    }

    // MARK: - Fetch Events

    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        let cursorState = decodeCursor(cursor)
        let sinceMs = cursorState?.lastTimestamp ?? 0

        let indexPath = (basePath as NSString).appendingPathComponent("tasks/_index.json")

        guard let indexData = FileManager.default.contents(atPath: indexPath),
              let taskIndex = try? JSONDecoder().decode(TaskIndex.self, from: indexData) else {
            return (events: [], newCursor: cursor)
        }

        let newTasks = taskIndex.entries
            .filter { $0.ts > sinceMs }
            .sorted { $0.ts < $1.ts }

        let apiConfigModelMap = loadApiConfigModelMap()

        var allEvents: [UsageEvent] = []
        var latestTimestamp: Int64 = sinceMs

        for task in newTasks {
            let taskEvents = extractEventsFromTask(task, apiConfigModelMap: apiConfigModelMap)
            allEvents.append(contentsOf: taskEvents)

            if task.ts > latestTimestamp {
                latestTimestamp = task.ts
            }

            for event in taskEvents {
                let eventMs = Int64(event.observedAt.timeIntervalSince1970 * 1000)
                if eventMs > latestTimestamp {
                    latestTimestamp = eventMs
                }
            }
        }

        let newCursor: String?
        if latestTimestamp > sinceMs {
            newCursor = encodeCursor(CursorState(lastTimestamp: latestTimestamp))
        } else {
            newCursor = cursor
        }

        return (events: allEvents, newCursor: newCursor)
    }

    // MARK: - Health Check

    func healthCheck() -> SourceHealth {
        let indexPath = (basePath as NSString).appendingPathComponent("tasks/_index.json")

        guard FileManager.default.fileExists(atPath: indexPath) else {
            return SourceHealth(
                source: .roo,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Index file not found at \(indexPath)",
                eventCount: 0
            )
        }

        guard let indexData = FileManager.default.contents(atPath: indexPath),
              let taskIndex = try? JSONDecoder().decode(TaskIndex.self, from: indexData) else {
            return SourceHealth(
                source: .roo,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Failed to parse index file",
                eventCount: 0
            )
        }

        let latestTs = taskIndex.entries.map(\.ts).max()
        let lastEventTime = latestTs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }

        return SourceHealth(
            source: .roo,
            isHealthy: true,
            lastEventTime: lastEventTime,
            errorMessage: nil,
            eventCount: taskIndex.entries.count
        )
    }

    // MARK: - Private Helpers

    private func extractEventsFromTask(_ task: TaskEntry, apiConfigModelMap: [String: String]) -> [UsageEvent] {
        // Use _index.json totals as the authoritative token counts.
        //
        // We previously parsed ui_messages.json and computed per-request deltas from
        // cumulative token values. That approach breaks when Roo Code resets its
        // cumulative counter mid-task (e.g. after context condensation), causing
        // massive undercounting (e.g. 936K reported vs 46.5M actual).
        //
        // The _index.json entry already carries the correct lifetime totals for the
        // task, so we emit one UsageEvent per task using those values. This is
        // simpler, more reliable, and matches what Roo Code itself reports.
        let totalIn = task.tokensIn ?? 0
        let totalOut = task.tokensOut ?? 0
        let totalTokens = totalIn + totalOut

        guard totalTokens > 0 else { return [] }

        let projectName = task.workspace.flatMap { workspace -> String? in
            guard !workspace.isEmpty else { return nil }
            return URL(fileURLWithPath: workspace).lastPathComponent
        }

        let observedAt = Date(timeIntervalSince1970: Double(task.ts) / 1000.0)
        let resolvedModel = task.apiConfigName.flatMap { apiConfigModelMap[$0] } ?? task.apiConfigName

        let event = UsageEvent(
            id: task.id,
            observedAt: observedAt,
            source: .roo,
            sessionID: task.id,
            sessionTitle: task.task,
            requestID: task.id,
            projectName: projectName,
            repoPath: task.workspace,
            provider: task.apiConfigName,
            model: resolvedModel,
            agent: task.mode,
            promptTokens: totalIn,
            completionTokens: totalOut,
            cachedReadTokens: task.cacheReads ?? 0,
            cachedWriteTokens: task.cacheWrites ?? 0,
            reasoningTokens: 0,
            totalTokens: totalTokens,
            estimatedCostUSD: task.totalCost ?? 0.0
        )

        return [event]
    }

    private func decodeCursor(_ cursor: String?) -> CursorState? {
        guard let cursorString = cursor,
              let data = cursorString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CursorState.self, from: data)
    }

    private func encodeCursor(_ state: CursorState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
