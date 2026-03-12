import Foundation

// MARK: - RooCodeReader

final class RooCodeReader {

    // MARK: - Properties

    private let basePath: String

    static let defaultBasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"
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

    // MARK: - UI Message Types

    private struct UIMessage: Decodable {
        let ts: Int64?
        let type: String?
        let say: String?
        let text: String?
    }

    /// Embedded JSON inside api_req_started text field — cumulative token counts within a task.
    private struct APIRequestPayload: Decodable {
        let tokensIn: Int?
        let tokensOut: Int?
        let cacheWrites: Int?
        let cacheReads: Int?
        let cost: Double?
    }

    // MARK: - Initialization

    init(basePath: String = RooCodeReader.defaultBasePath) {
        self.basePath = basePath
    }

    // MARK: - Fetch Events

    /// Cursor is JSON `{"lastTimestamp": <epoch_ms>}`. Returns per-request delta events + updated cursor.
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

        var allEvents: [UsageEvent] = []
        var latestTimestamp: Int64 = sinceMs

        for task in newTasks {
            let taskEvents = extractEventsFromTask(task)
            allEvents.append(contentsOf: taskEvents)

            if task.ts > latestTimestamp {
                latestTimestamp = task.ts
            }

            // Also track the latest individual event timestamp for accurate cursor.
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

    /// Reads ui_messages.json for a task and computes per-request deltas from cumulative api_req_started events.
    /// CRITICAL: tokensIn/tokensOut in api_req_started are CUMULATIVE within a task.
    /// Each event's actual usage = current cumulative - previous cumulative.
    private func extractEventsFromTask(_ task: TaskEntry) -> [UsageEvent] {
        let messagesPath = (basePath as NSString)
            .appendingPathComponent("tasks/\(task.id)/ui_messages.json")

        guard let data = FileManager.default.contents(atPath: messagesPath),
              let messages = try? JSONDecoder().decode([UIMessage].self, from: data) else {
            return []
        }

        let apiRequests = messages.filter { $0.type == "say" && $0.say == "api_req_started" }

        var events: [UsageEvent] = []
        var previousIn = 0
        var previousOut = 0
        var previousCacheReads = 0
        var previousCacheWrites = 0

        let projectName = task.workspace.flatMap { workspace -> String? in
            guard !workspace.isEmpty else { return nil }
            return URL(fileURLWithPath: workspace).lastPathComponent
        }

        for (index, request) in apiRequests.enumerated() {
            guard let textJSON = request.text,
                  let textData = textJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(APIRequestPayload.self, from: textData) else {
                continue
            }

            let currentIn = payload.tokensIn ?? 0
            let currentOut = payload.tokensOut ?? 0
            let currentCacheReads = payload.cacheReads ?? 0
            let currentCacheWrites = payload.cacheWrites ?? 0

            // Compute deltas from cumulative values.
            let deltaIn = currentIn - previousIn
            let deltaOut = currentOut - previousOut
            let deltaCacheReads = currentCacheReads - previousCacheReads
            let deltaCacheWrites = currentCacheWrites - previousCacheWrites
            let deltaTotal = deltaIn + deltaOut

            previousIn = currentIn
            previousOut = currentOut
            previousCacheReads = currentCacheReads
            previousCacheWrites = currentCacheWrites

            guard deltaTotal > 0 else { continue }

            let timestamp = request.ts ?? task.ts
            let observedAt = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)

            let sessionTitle = task.task

            let event = UsageEvent(
                id: "\(task.id)-\(index)",
                observedAt: observedAt,
                source: .roo,
                sessionID: task.id,
                sessionTitle: sessionTitle,
                requestID: "\(task.id)-\(index)",
                projectName: projectName,
                repoPath: task.workspace,
                provider: task.apiConfigName,
                model: task.apiConfigName,
                agent: task.mode,
                promptTokens: deltaIn,
                completionTokens: deltaOut,
                cachedReadTokens: deltaCacheReads,
                cachedWriteTokens: deltaCacheWrites,
                reasoningTokens: 0,
                totalTokens: deltaTotal,
                estimatedCostUSD: payload.cost ?? 0.0
            )

            events.append(event)
        }

        return events
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
