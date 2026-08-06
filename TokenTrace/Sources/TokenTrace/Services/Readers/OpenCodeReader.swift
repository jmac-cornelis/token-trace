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
                        json_extract(m.data, '$.cost') AS cost,
                        (SELECT json_extract(pt.data, '$.text')
                         FROM part pt
                         JOIN message um ON pt.message_id = um.id
                         WHERE um.session_id = m.session_id
                           AND json_extract(um.data, '$.role') = 'user'
                         ORDER BY um.time_created DESC LIMIT 1
                        ) AS last_prompt
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

                // Cursor rather than fetchAll: a first-run scan returns ~120K rows and each
                // carries a duplicated `last_prompt` blob, so materializing the whole [Row]
                // array alongside the [UsageEvent] array doubled peak memory for no gain.
                let rows = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(arguments))

                var events: [UsageEvent] = []
                var latestTimestamp: String?
                var sessionCache: [String: SessionColumns] = [:]

                while let row = try rows.next() {
                    let messageId: String = row["message_id"]
                    let sessionId: String = row["session_id"]
                    let timeCreated: Int64 = row["time_created"]

                    let session: SessionColumns
                    if let cached = sessionCache[sessionId] {
                        session = cached
                    } else {
                        session = SessionColumns(row: row)
                        sessionCache[sessionId] = session
                    }

                    let modelId: String? = row["model_id"]
                    let providerId: String? = row["provider_id"]
                    let agent: String? = row["agent"]

                    // OpenCode wrote negative `tokens.output` on 1,786 assistant messages
                    // between 2026-03-11 and 2026-05-07 (as low as -45,363) before patching
                    // the bug upstream with the same clamp; `input`, `reasoning` and the
                    // cache counters were never affected but are floored as cheap invariants.
                    // `total` is deliberately NOT recomputed from the components: on 11,323
                    // post-patch rows OpenCode already reports `total < input + output` by up
                    // to 93,890 tokens, so recomputing would inflate reported volume.
                    let tokensTotal: Int = max(0, row["tokens_total"] ?? 0)
                    let tokensInput: Int = max(0, row["tokens_input"] ?? 0)
                    let tokensOutput: Int = max(0, row["tokens_output"] ?? 0)
                    let tokensReasoning: Int = max(0, row["tokens_reasoning"] ?? 0)
                    let cacheRead: Int = max(0, row["cache_read"] ?? 0)
                    let cacheWrite: Int = max(0, row["cache_write"] ?? 0)

                    let observedAt = Date(timeIntervalSince1970: Double(timeCreated) / 1000.0)

                    let reportedCost: Double = row["cost"] ?? 0.0
                    let cost = Self.resolveCost(
                        reportedCost: reportedCost,
                        model: modelId,
                        observedAt: observedAt,
                        promptTokens: tokensInput,
                        completionTokens: tokensOutput,
                        cachedReadTokens: cacheRead,
                        cachedWriteTokens: cacheWrite,
                        reasoningTokens: tokensReasoning
                    )

                    let event = UsageEvent(
                        id: messageId,
                        observedAt: observedAt,
                        source: .opencode,
                        sessionID: sessionId,
                        sessionTitle: session.title,
                        requestID: messageId,
                        projectName: session.projectName,
                        repoPath: session.repoPath,
                        provider: providerId,
                        model: modelId,
                        agent: agent,
                        promptTokens: tokensInput,
                        completionTokens: tokensOutput,
                        cachedReadTokens: cacheRead,
                        cachedWriteTokens: cacheWrite,
                        reasoningTokens: tokensReasoning,
                        totalTokens: tokensTotal,
                        estimatedCostUSD: cost,
                        lastPrompt: session.lastPrompt
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

    /// Per-session columns, cached so every row of a session shares one String
    /// instance instead of a copy. The `last_prompt` subquery repeats the session's
    /// latest prompt on every row it owns (232 MB across a full 120K-row scan), and
    /// title/path repeat the same way; interning them collapses that to one copy.
    private struct SessionColumns {
        let title: String?
        let projectName: String?
        let repoPath: String?
        let lastPrompt: String?

        init(row: Row) {
            title = row["session_title"]
            lastPrompt = row["last_prompt"]
            // Path is resolved before the name because the name is derived from it.
            let repoPath = OpenCodeReader.resolveRepoPath(
                worktree: row["project_worktree"] as String?,
                sessionDirectory: row["session_directory"] as String?
            )
            self.repoPath = repoPath
            projectName = OpenCodeReader.resolveProjectName(
                projectName: row["project_name"] as String?,
                repoPath: repoPath
            )
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

    // MARK: - Cost Resolution

    /// OpenCode leaves `$.cost` at 0 for ~26K historical assistant messages (all rows
    /// before 2026-04-18, plus later subagent turns) even though token counts are
    /// present, which silently under-reports spend. Fall back to local pricing only
    /// when the model has a published price; models like "assistant" stay at 0 rather
    /// than being charged the mid-range guess.
    static func resolveCost(
        reportedCost: Double,
        model: String?,
        observedAt: Date,
        promptTokens: Int,
        completionTokens: Int,
        cachedReadTokens: Int,
        cachedWriteTokens: Int,
        reasoningTokens: Int
    ) -> Double {
        guard reportedCost <= 0,
              promptTokens + completionTokens + reasoningTokens > 0,
              CostEstimator.hasKnownPricing(for: model) else {
            // 42 rows carry a negative `$.cost` straight from OpenCode; never pass one through.
            return max(0, reportedCost)
        }

        return CostEstimator.estimateCostFromEvents(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedReadTokens: cachedReadTokens,
            cachedWriteTokens: cachedWriteTokens,
            reasoningTokens: reasoningTokens,
            model: model,
            observedAt: observedAt
        )
    }

    // MARK: - Path / Name Resolution

    /// Paths that identify no real workspace. OpenCode inserts a synthetic project row
    /// `id='global'` with `worktree='/'` for every session started outside a git repo
    /// (1,145 of ~1,900 sessions locally), so `/` must be rejected rather than trusted.
    private static let nonWorkspacePaths: Set<String> = ["/", ""]

    /// Priority: project.worktree (when it names a real workspace) -> session.directory.
    static func resolveRepoPath(worktree: String?, sessionDirectory: String?) -> String? {
        if let tree = worktree?.trimmingCharacters(in: .whitespaces),
           !nonWorkspacePaths.contains(tree) {
            return tree
        }
        if let dir = sessionDirectory?.trimmingCharacters(in: .whitespaces),
           !nonWorkspacePaths.contains(dir) {
            return dir
        }
        return nil
    }

    /// Priority: project.name -> basename of the already-resolved repo path -> nil.
    static func resolveProjectName(projectName: String?, repoPath: String?) -> String? {
        if let name = projectName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        guard let repoPath else { return nil }
        let basename = URL(fileURLWithPath: repoPath).lastPathComponent
        return nonWorkspacePaths.contains(basename) ? nil : basename
    }
}
