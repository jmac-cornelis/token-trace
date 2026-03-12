import Foundation
import GRDB

// MARK: - OpenCodeReader

final class OpenCodeReader {

    // MARK: - Properties

    private let dbPath: String
    private var dbQueue: DatabaseQueue?

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/opencode/opencode.db"
    }()

    // MARK: - Initialization

    init(dbPath: String = OpenCodeReader.defaultPath) {
        self.dbPath = dbPath
    }

    // MARK: - Connection

    func connect() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ReaderError.databaseNotFound(dbPath)
        }

        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    }

    // MARK: - Fetch Events

    /// Cursor is the last `time_created` epoch ms string. Returns new events + updated cursor.
    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        guard let db = dbQueue else {
            return (events: [], newCursor: cursor)
        }

        do {
            let results = try db.read { db -> (events: [UsageEvent], newCursor: String?) in
                // JOIN message -> session -> project; filter assistant messages with tokens > 0;
                // use json_extract() for token fields; order by time_created ASC for cursor advancement.
                var sql = """
                    SELECT
                        m.id AS message_id,
                        m.session_id,
                        m.time_created,
                        s.title AS session_title,
                        s.directory AS session_directory,
                        p.name AS project_name,
                        p.worktree AS project_worktree,
                        json_extract(m.data, '$.modelID') AS model_id,
                        json_extract(m.data, '$.providerID') AS provider_id,
                        json_extract(m.data, '$.agent') AS agent,
                        json_extract(m.data, '$.tokens.total') AS tokens_total,
                        json_extract(m.data, '$.tokens.input') AS tokens_input,
                        json_extract(m.data, '$.tokens.output') AS tokens_output,
                        json_extract(m.data, '$.tokens.reasoning') AS tokens_reasoning,
                        json_extract(m.data, '$.tokens.cache.read') AS cache_read,
                        json_extract(m.data, '$.tokens.cache.write') AS cache_write,
                        json_extract(m.data, '$.cost') AS cost
                    FROM message m
                    JOIN session s ON m.session_id = s.id
                    LEFT JOIN project p ON s.project_id = p.id
                    WHERE json_extract(m.data, '$.role') = 'assistant'
                      AND COALESCE(json_extract(m.data, '$.tokens.total'), 0) > 0
                    """

                var arguments: [DatabaseValueConvertible] = []

                if let cursorValue = cursor, let cursorMs = Int64(cursorValue) {
                    sql += " AND m.time_created > ?"
                    arguments.append(cursorMs)
                }

                sql += " ORDER BY m.time_created ASC"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

                var events: [UsageEvent] = []
                var latestTimestamp: String?

                for row in rows {
                    let messageId: String = row["message_id"]
                    let sessionId: String = row["session_id"]
                    let timeCreated: Int64 = row["time_created"]

                    let projectName = resolveProjectName(
                        projectName: row["project_name"] as String?,
                        worktree: row["project_worktree"] as String?,
                        sessionDirectory: row["session_directory"] as String?
                    )

                    let repoPath = (row["project_worktree"] as String?)
                        ?? (row["session_directory"] as String?)

                    let modelId: String? = row["model_id"]
                    let providerId: String? = row["provider_id"]
                    let agent: String? = row["agent"]

                    let tokensTotal: Int = row["tokens_total"] ?? 0
                    let tokensInput: Int = row["tokens_input"] ?? 0
                    let tokensOutput: Int = row["tokens_output"] ?? 0
                    let tokensReasoning: Int = row["tokens_reasoning"] ?? 0
                    let cacheRead: Int = row["cache_read"] ?? 0
                    let cacheWrite: Int = row["cache_write"] ?? 0
                    let cost: Double = row["cost"] ?? 0.0

                    let observedAt = Date(timeIntervalSince1970: Double(timeCreated) / 1000.0)

                    let sessionTitle: String? = row["session_title"]

                    let event = UsageEvent(
                        id: messageId,
                        observedAt: observedAt,
                        source: .opencode,
                        sessionID: sessionId,
                        sessionTitle: sessionTitle,
                        requestID: messageId,
                        projectName: projectName,
                        repoPath: repoPath,
                        provider: providerId,
                        model: modelId,
                        agent: agent,
                        promptTokens: tokensInput,
                        completionTokens: tokensOutput,
                        cachedReadTokens: cacheRead,
                        cachedWriteTokens: cacheWrite,
                        reasoningTokens: tokensReasoning,
                        totalTokens: tokensTotal,
                        estimatedCostUSD: cost
                    )

                    events.append(event)
                    latestTimestamp = String(timeCreated)
                }

                let newCursor = latestTimestamp ?? cursor
                return (events: events, newCursor: newCursor)
            }

            return results
        } catch {
            return (events: [], newCursor: cursor)
        }
    }

    // MARK: - Health Check

    func healthCheck() -> SourceHealth {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return SourceHealth(
                source: .opencode,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database not found at \(dbPath)",
                eventCount: 0
            )
        }

        guard let db = dbQueue else {
            return SourceHealth(
                source: .opencode,
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
                        MAX(m.time_created) AS last_time,
                        COUNT(*) AS event_count
                    FROM message m
                    WHERE json_extract(m.data, '$.role') = 'assistant'
                      AND COALESCE(json_extract(m.data, '$.tokens.total'), 0) > 0
                    """)

                let lastTimeMs: Int64? = row?["last_time"]
                let eventCount: Int = row?["event_count"] ?? 0
                let lastDate = lastTimeMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                return (lastDate, eventCount)
            }

            return SourceHealth(
                source: .opencode,
                isHealthy: true,
                lastEventTime: lastTime,
                errorMessage: nil,
                eventCount: count
            )
        } catch {
            return SourceHealth(
                source: .opencode,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database read error: \(error.localizedDescription)",
                eventCount: 0
            )
        }
    }

    // MARK: - Private Helpers

    /// Priority: project.name -> worktree basename -> session directory basename -> nil
    private func resolveProjectName(
        projectName: String?,
        worktree: String?,
        sessionDirectory: String?
    ) -> String? {
        if let name = projectName, !name.isEmpty {
            return name
        }
        if let tree = worktree, !tree.isEmpty {
            return URL(fileURLWithPath: tree).lastPathComponent
        }
        if let dir = sessionDirectory, !dir.isEmpty {
            return URL(fileURLWithPath: dir).lastPathComponent
        }
        return nil
    }
}
