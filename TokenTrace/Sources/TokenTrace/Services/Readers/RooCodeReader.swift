import Foundation
import SQLite3

struct RooTaskSnapshot {
    let taskID: String
    let tokensIn: Int
    let tokensOut: Int
    let cacheWrites: Int
    let cacheReads: Int
    let totalCost: Double
    let lastTimestamp: Int64
    let status: String?
    let firstSeenAt: Date
}

protocol RooTaskSnapshotStore {
    func snapshots(for taskIDs: [String]) throws -> [String: RooTaskSnapshot]
    func saveSnapshots(_ snapshots: [RooTaskSnapshot]) throws
}

final class InMemoryRooTaskSnapshotStore: RooTaskSnapshotStore {
    private var snapshotsByTaskID: [String: RooTaskSnapshot] = [:]

    func snapshots(for taskIDs: [String]) throws -> [String: RooTaskSnapshot] {
        var result: [String: RooTaskSnapshot] = [:]
        for taskID in taskIDs {
            if let snapshot = snapshotsByTaskID[taskID] {
                result[taskID] = snapshot
            }
        }
        return result
    }

    func saveSnapshots(_ snapshots: [RooTaskSnapshot]) throws {
        for snapshot in snapshots {
            snapshotsByTaskID[snapshot.taskID] = snapshot
        }
    }
}

final class RooCodeReader {

    private let basePath: String
    private let snapshotStore: any RooTaskSnapshotStore

    static let defaultBasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"
    }()

    private static let vscodeStatePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/globalStorage/state.vscdb"
    }()

    private struct CursorState: Codable {
        let lastTimestamp: Int64
    }

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

    private struct DeltaResult {
        let event: UsageEvent?
        let snapshot: RooTaskSnapshot
    }

    private struct ApiConfigMeta: Decodable {
        let name: String
        let id: String
        let apiProvider: String?
        let modelId: String?
    }

    private struct UIMessage: Decodable {
        let ts: Int64?
        let type: String?
        let say: String?
        let text: String?
    }

    private struct ApiRequestPayload: Decodable {
        let tokensIn: Int?
        let tokensOut: Int?
        let cacheWrites: Int?
        let cacheReads: Int?
        let cost: Double?
    }

    init(
        basePath: String = RooCodeReader.defaultBasePath,
        snapshotStore: any RooTaskSnapshotStore = InMemoryRooTaskSnapshotStore()
    ) {
        self.basePath = basePath
        self.snapshotStore = snapshotStore
    }

    private func loadApiConfigModelMap() -> [String: String] {
        let dbPath = RooCodeReader.vscodeStatePath
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        var db: OpaquePointer?
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

        var map: [String: String] = [:]
        for config in configs {
            if let modelId = config.modelId, !modelId.isEmpty {
                map[config.name] = modelId
            }
        }
        return map
    }

    func fetchEvents(since cursor: String?) throws -> (events: [UsageEvent], newCursor: String?) {
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

        if newTasks.isEmpty {
            return (events: [], newCursor: cursor)
        }

        let apiConfigModelMap = loadApiConfigModelMap()
        let bootstrapScan = cursorState == nil
        let existingSnapshots = try snapshotStore.snapshots(for: newTasks.map { $0.id })
        let startOfToday = Calendar.current.startOfDay(for: Date())

        var allEvents: [UsageEvent] = []
        var pendingSnapshots: [RooTaskSnapshot] = []
        var latestTimestamp: Int64 = sinceMs

        for task in newTasks {
            let delta = deltaResult(
                for: task,
                existingSnapshot: existingSnapshots[task.id],
                bootstrapScan: bootstrapScan,
                startOfToday: startOfToday,
                apiConfigModelMap: apiConfigModelMap
            )

            if let event = delta.event {
                allEvents.append(event)
            }
            pendingSnapshots.append(delta.snapshot)
            latestTimestamp = max(latestTimestamp, task.ts)
        }

        if !pendingSnapshots.isEmpty {
            try snapshotStore.saveSnapshots(pendingSnapshots)
        }

        let newCursor: String?
        if latestTimestamp > sinceMs {
            newCursor = encodeCursor(CursorState(lastTimestamp: latestTimestamp))
        } else {
            newCursor = cursor
        }

        return (events: allEvents, newCursor: newCursor)
    }

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

    private func deltaResult(
        for task: TaskEntry,
        existingSnapshot: RooTaskSnapshot?,
        bootstrapScan: Bool,
        startOfToday: Date,
        apiConfigModelMap: [String: String]
    ) -> DeltaResult {
        let observedAt = Date(timeIntervalSince1970: Double(task.ts) / 1000.0)
        let currentSnapshot = makeSnapshot(
            from: task,
            firstSeenAt: existingSnapshot?.firstSeenAt ?? observedAt
        )

        if let existingSnapshot {
            return DeltaResult(
                event: makeDeltaEvent(
                    from: task,
                    observedAt: observedAt,
                    apiConfigModelMap: apiConfigModelMap,
                    existingSnapshot: existingSnapshot,
                    currentSnapshot: currentSnapshot
                ),
                snapshot: currentSnapshot
            )
        }

        if bootstrapScan {
            return DeltaResult(
                event: makeBootstrapEvent(
                    from: task,
                    startOfToday: startOfToday,
                    apiConfigModelMap: apiConfigModelMap
                ),
                snapshot: currentSnapshot
            )
        }

        return DeltaResult(
            event: makeInitialEvent(
                from: task,
                observedAt: observedAt,
                apiConfigModelMap: apiConfigModelMap,
                currentSnapshot: currentSnapshot
            ),
            snapshot: currentSnapshot
        )
    }

    private func makeSnapshot(from task: TaskEntry, firstSeenAt: Date) -> RooTaskSnapshot {
        RooTaskSnapshot(
            taskID: task.id,
            tokensIn: task.tokensIn ?? 0,
            tokensOut: task.tokensOut ?? 0,
            cacheWrites: task.cacheWrites ?? 0,
            cacheReads: task.cacheReads ?? 0,
            totalCost: task.totalCost ?? 0,
            lastTimestamp: task.ts,
            status: task.status,
            firstSeenAt: firstSeenAt
        )
    }

    private func makeInitialEvent(
        from task: TaskEntry,
        observedAt: Date,
        apiConfigModelMap: [String: String],
        currentSnapshot: RooTaskSnapshot
    ) -> UsageEvent? {
        let totalTokens = currentSnapshot.tokensIn + currentSnapshot.tokensOut
        let hasUsage = totalTokens > 0
            || currentSnapshot.cacheReads > 0
            || currentSnapshot.cacheWrites > 0
            || currentSnapshot.totalCost > 0

        guard hasUsage else { return nil }

        return makeEvent(
            id: "\(task.id)-\(task.ts)",
            task: task,
            observedAt: observedAt,
            apiConfigModelMap: apiConfigModelMap,
            promptTokens: currentSnapshot.tokensIn,
            completionTokens: currentSnapshot.tokensOut,
            cachedReadTokens: currentSnapshot.cacheReads,
            cachedWriteTokens: currentSnapshot.cacheWrites,
            estimatedCostUSD: currentSnapshot.totalCost
        )
    }

    private func makeBootstrapEvent(
        from task: TaskEntry,
        startOfToday: Date,
        apiConfigModelMap: [String: String]
    ) -> UsageEvent? {
        guard let usage = bootstrapUsage(for: task.id, startOfToday: startOfToday) else {
            return nil
        }

        return makeEvent(
            id: "\(task.id)-bootstrap-\(Int64(startOfToday.timeIntervalSince1970 * 1000))",
            task: task,
            observedAt: usage.observedAt,
            apiConfigModelMap: apiConfigModelMap,
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            cachedReadTokens: usage.cachedReadTokens,
            cachedWriteTokens: usage.cachedWriteTokens,
            estimatedCostUSD: usage.estimatedCostUSD
        )
    }

    private func bootstrapUsage(for taskID: String, startOfToday: Date) -> (
        observedAt: Date,
        promptTokens: Int,
        completionTokens: Int,
        cachedReadTokens: Int,
        cachedWriteTokens: Int,
        estimatedCostUSD: Double
    )? {
        let messagesPath = (basePath as NSString).appendingPathComponent("tasks/\(taskID)/ui_messages.json")
        guard let data = FileManager.default.contents(atPath: messagesPath),
              let messages = try? JSONDecoder().decode([UIMessage].self, from: data) else {
            return nil
        }

        let startOfTodayMs = Int64(startOfToday.timeIntervalSince1970 * 1000)
        var latestTimestamp = startOfTodayMs
        var promptTokens = 0
        var completionTokens = 0
        var cachedReadTokens = 0
        var cachedWriteTokens = 0
        var estimatedCostUSD = 0.0

        for message in messages {
            guard message.type == "say",
                  message.say == "api_req_started",
                  let timestamp = message.ts,
                  timestamp >= startOfTodayMs,
                  let text = message.text,
                  let payloadData = text.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ApiRequestPayload.self, from: payloadData) else {
                continue
            }

            promptTokens += payload.tokensIn ?? 0
            completionTokens += payload.tokensOut ?? 0
            cachedReadTokens += payload.cacheReads ?? 0
            cachedWriteTokens += payload.cacheWrites ?? 0
            estimatedCostUSD += payload.cost ?? 0
            latestTimestamp = max(latestTimestamp, timestamp)
        }

        let hasUsage = promptTokens > 0
            || completionTokens > 0
            || cachedReadTokens > 0
            || cachedWriteTokens > 0
            || estimatedCostUSD > 0

        guard hasUsage else { return nil }

        return (
            observedAt: Date(timeIntervalSince1970: Double(latestTimestamp) / 1000.0),
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedReadTokens: cachedReadTokens,
            cachedWriteTokens: cachedWriteTokens,
            estimatedCostUSD: estimatedCostUSD
        )
    }

    private func makeDeltaEvent(
        from task: TaskEntry,
        observedAt: Date,
        apiConfigModelMap: [String: String],
        existingSnapshot: RooTaskSnapshot,
        currentSnapshot: RooTaskSnapshot
    ) -> UsageEvent? {
        let deltaPrompt = max(0, currentSnapshot.tokensIn - existingSnapshot.tokensIn)
        let deltaCompletion = max(0, currentSnapshot.tokensOut - existingSnapshot.tokensOut)
        let deltaCachedRead = max(0, currentSnapshot.cacheReads - existingSnapshot.cacheReads)
        let deltaCachedWrite = max(0, currentSnapshot.cacheWrites - existingSnapshot.cacheWrites)
        let deltaCost = max(0, currentSnapshot.totalCost - existingSnapshot.totalCost)

        let hasUsage = deltaPrompt > 0
            || deltaCompletion > 0
            || deltaCachedRead > 0
            || deltaCachedWrite > 0
            || deltaCost > 0

        guard hasUsage else { return nil }

        return makeEvent(
            id: "\(task.id)-\(task.ts)",
            task: task,
            observedAt: observedAt,
            apiConfigModelMap: apiConfigModelMap,
            promptTokens: deltaPrompt,
            completionTokens: deltaCompletion,
            cachedReadTokens: deltaCachedRead,
            cachedWriteTokens: deltaCachedWrite,
            estimatedCostUSD: deltaCost
        )
    }

    private func makeEvent(
        id: String,
        task: TaskEntry,
        observedAt: Date,
        apiConfigModelMap: [String: String],
        promptTokens: Int,
        completionTokens: Int,
        cachedReadTokens: Int,
        cachedWriteTokens: Int,
        estimatedCostUSD: Double
    ) -> UsageEvent {
        let projectName = task.workspace.flatMap { workspace -> String? in
            guard !workspace.isEmpty else { return nil }
            return URL(fileURLWithPath: workspace).lastPathComponent
        }
        let resolvedModel = task.apiConfigName.flatMap { apiConfigModelMap[$0] } ?? task.apiConfigName

        return UsageEvent(
            id: id,
            observedAt: observedAt,
            source: .roo,
            sessionID: task.id,
            sessionTitle: task.task,
            requestID: id,
            projectName: projectName,
            repoPath: task.workspace,
            provider: task.apiConfigName,
            model: resolvedModel,
            agent: task.mode,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedReadTokens: cachedReadTokens,
            cachedWriteTokens: cachedWriteTokens,
            reasoningTokens: 0,
            totalTokens: promptTokens + completionTokens,
            estimatedCostUSD: estimatedCostUSD
        )
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
