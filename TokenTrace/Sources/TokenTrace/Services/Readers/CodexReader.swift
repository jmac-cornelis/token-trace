import Foundation
import GRDB

final class CodexReader {

    private let dbPath: String
    private let codexHome: String
    private var dbQueue: DatabaseQueue?

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/state_5.sqlite"
    }()

    static let defaultHome: String = {
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return envHome
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex"
    }()

    init(dbPath: String = CodexReader.defaultPath, codexHome: String = CodexReader.defaultHome) {
        self.dbPath = dbPath
        self.codexHome = codexHome
    }

    func connect() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ReaderError.databaseNotFound(dbPath)
        }

        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    }

    private struct CursorState: Codable {
        var updatedAt: Int64
        var threadOffsets: [String: Int]
    }

    private func decodeCursor(_ cursor: String?) -> CursorState? {
        guard let cursor = cursor,
              let data = cursor.data(using: .utf8),
              let state = try? JSONDecoder().decode(CursorState.self, from: data) else {
            return nil
        }
        return state
    }

    private func encodeCursor(_ state: CursorState) -> String? {
        guard let data = try? JSONEncoder().encode(state),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        guard let db = dbQueue else {
            return (events: [], newCursor: cursor)
        }

        do {
            let results = try db.read { db -> (events: [UsageEvent], newCursor: String?) in
                var cursorState = decodeCursor(cursor) ?? CursorState(updatedAt: 0, threadOffsets: [:])

                let sql = """
                    SELECT
                        id, title, cwd, model_provider, model, tokens_used,
                        source, created_at, updated_at, git_branch,
                        git_origin_url, cli_version, first_user_message,
                        rollout_path
                    FROM threads
                    WHERE tokens_used > 0
                    ORDER BY updated_at ASC
                    """

                let rows = try Row.fetchAll(db, sql: sql)

                var events: [UsageEvent] = []
                var maxUpdatedAt: Int64 = cursorState.updatedAt

                for row in rows {
                    let threadId: String = row["id"]
                    let createdAt: Int64 = row["created_at"]
                    let updatedAt: Int64 = row["updated_at"]
                    let tokensUsed: Int = row["tokens_used"] ?? 0
                    let title: String? = row["title"]
                    let cwd: String? = row["cwd"]
                    let modelProvider: String? = row["model_provider"]
                    let modelName: String? = row["model"]
                    let firstMessage: String? = row["first_user_message"]
                    let rolloutPath: String? = row["rollout_path"]

                    if updatedAt > maxUpdatedAt {
                        maxUpdatedAt = updatedAt
                    }

                    let projectName = cwd.flatMap { path -> String? in
                        guard !path.isEmpty else { return nil }
                        return URL(fileURLWithPath: path).lastPathComponent
                    }

                    let sessionTitle = title ?? firstMessage.map { msg in
                        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.count > 80 ? String(trimmed.prefix(77)) + "..." : trimmed
                    }

                    let lastStoredIndex = cursorState.threadOffsets[threadId] ?? -1

                    let rolloutEvents = parseRolloutEvents(
                        rolloutPath: rolloutPath,
                        threadId: threadId,
                        startIndex: lastStoredIndex + 1
                    )

                    if rolloutEvents.isEmpty && lastStoredIndex < 0 {
                        let observedAt = Date(timeIntervalSince1970: Double(createdAt))
                        let event = UsageEvent(
                            id: "codex-\(threadId)",
                            observedAt: observedAt,
                            source: .codex,
                            sessionID: threadId,
                            sessionTitle: sessionTitle,
                            requestID: nil,
                            projectName: projectName,
                            repoPath: cwd,
                            provider: modelProvider,
                            model: modelName ?? modelProvider,
                            agent: nil,
                            promptTokens: 0,
                            completionTokens: 0,
                            cachedReadTokens: 0,
                            cachedWriteTokens: 0,
                            reasoningTokens: 0,
                            totalTokens: tokensUsed,
                            estimatedCostUSD: 0.0,
                            lastPrompt: firstMessage
                        )
                        events.append(event)
                        cursorState.threadOffsets[threadId] = -2
                    } else if !rolloutEvents.isEmpty {
                        let baseIndex = lastStoredIndex + 1
                        for (offset, re) in rolloutEvents.enumerated() {
                            let absoluteIndex = baseIndex + offset
                            let event = UsageEvent(
                                id: "codex-\(threadId)-\(absoluteIndex)",
                                observedAt: re.timestamp,
                                source: .codex,
                                sessionID: threadId,
                                sessionTitle: sessionTitle,
                                requestID: "req-\(absoluteIndex)",
                                projectName: projectName,
                                repoPath: cwd,
                                provider: modelProvider,
                                model: re.model ?? modelName ?? modelProvider,
                                agent: nil,
                                promptTokens: re.inputTokens,
                                // Codex output_tokens includes reasoning; we track reasoning
                                // separately, so subtract it to keep completion reasoning-free
                                // (the cost layer's keystone: completion never double-counts reasoning).
                                completionTokens: max(0, re.outputTokens - re.reasoningTokens),
                                cachedReadTokens: re.cachedInputTokens,
                                cachedWriteTokens: 0,
                                reasoningTokens: re.reasoningTokens,
                                totalTokens: re.totalTokens,
                                estimatedCostUSD: 0.0,
                                lastPrompt: nil
                            )
                            events.append(event)
                        }
                        let newLastIndex = baseIndex + rolloutEvents.count - 1
                        cursorState.threadOffsets[threadId] = newLastIndex
                    }
                }

                cursorState.updatedAt = maxUpdatedAt
                let newCursor = encodeCursor(cursorState) ?? cursor
                return (events: events, newCursor: newCursor)
            }

            return results
        } catch {
            return (events: [], newCursor: cursor)
        }
    }

    private struct RolloutEvent {
        let timestamp: Date
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int
        let model: String?
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseRolloutEvents(rolloutPath: String?, threadId: String, startIndex: Int = 0) -> [RolloutEvent] {
        guard let path = resolveRolloutPath(rolloutPath, threadId: threadId) else {
            return []
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [RolloutEvent] = []
        var prevCumulativeTotal = 0
        var currentModel: String?
        var validEntryCount = 0

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let lineType = json["type"] as? String ?? ""

            if lineType == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
            }

            guard lineType == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String, payloadType == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any],
                  let lastUsage = info["last_token_usage"] as? [String: Any] else {
                continue
            }

            let cumulativeTotal = totalUsage["total_tokens"] as? Int ?? 0

            guard cumulativeTotal > prevCumulativeTotal else {
                continue
            }

            if validEntryCount < startIndex {
                validEntryCount += 1
                prevCumulativeTotal = cumulativeTotal
                continue
            }

            let timestampStr = json["timestamp"] as? String ?? ""
            let timestamp = Self.isoFormatter.date(from: timestampStr)
                ?? Self.isoFallback.date(from: timestampStr)
                ?? Date()

            let inputTokens = lastUsage["input_tokens"] as? Int ?? 0
            let cachedInput = lastUsage["cached_input_tokens"] as? Int ?? 0
            let outputTokens = lastUsage["output_tokens"] as? Int ?? 0
            let reasoningTokens = lastUsage["reasoning_output_tokens"] as? Int ?? 0
            let lastTotal = lastUsage["total_tokens"] as? Int ?? 0

            let eventTotal = lastTotal > 0 ? lastTotal : (cumulativeTotal - prevCumulativeTotal)

            results.append(RolloutEvent(
                timestamp: timestamp,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInput,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                totalTokens: eventTotal,
                model: currentModel
            ))

            prevCumulativeTotal = cumulativeTotal
            validEntryCount += 1
        }

        return results
    }

    private func resolveRolloutPath(_ rolloutPath: String?, threadId: String) -> String? {
        if let rp = rolloutPath, !rp.isEmpty {
            if rp.hasPrefix("/") {
                return rp
            }
            return (codexHome as NSString).appendingPathComponent(rp)
        }

        let sessionsDir = (codexHome as NSString).appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir) else {
            return nil
        }

        if let found = findRolloutFile(in: sessionsDir, matching: threadId) {
            return found
        }

        return nil
    }

    private func findRolloutFile(in directory: String, matching threadId: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return nil }

        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".jsonl") && path.contains(threadId) {
                return (directory as NSString).appendingPathComponent(path)
            }
        }
        return nil
    }

    func healthCheck() -> SourceHealth {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database not found at \(dbPath)",
                eventCount: 0
            )
        }

        guard let db = dbQueue else {
            return SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Not connected to database",
                eventCount: 0
            )
        }

        do {
            let (lastTime, count) = try db.read { db -> (Date?, Int) in
                let row = try Row.fetchOne(db, sql: """
                    SELECT
                        MAX(updated_at) AS last_time,
                        COUNT(*) AS event_count
                    FROM threads
                    WHERE tokens_used > 0
                    """)

                let lastTimeMs: Int64? = row?["last_time"]
                let eventCount: Int = row?["event_count"] ?? 0
                let lastDate = lastTimeMs.map { Date(timeIntervalSince1970: Double($0)) }
                return (lastDate, eventCount)
            }

            return SourceHealth(
                source: .codex,
                isHealthy: true,
                lastEventTime: lastTime,
                errorMessage: nil,
                eventCount: count
            )
        } catch {
            return SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database read error: \(error.localizedDescription)",
                eventCount: 0
            )
        }
    }
}
