import Foundation
import GRDB

// MARK: - OpenCodeReader

final class OpenCodeReader {

    // MARK: - Properties

    private let dbPaths: [String]
    private var dbQueues: [String: DatabaseQueue] = [:]

    static let defaultPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            paths.append((xdg as NSString).appendingPathComponent("opencode/opencode.db"))
        }
        paths.append("\(home)/.local/share/opencode/opencode.db")
        paths.append("\(home)/.local/opencode-2x/data/opencode/opencode.db")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }()

    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/opencode/opencode.db"
    }

    // MARK: - Initialization

    init(dbPath: String) {
        self.dbPaths = [dbPath]
    }

    init(dbPaths: [String] = OpenCodeReader.defaultPaths) {
        self.dbPaths = dbPaths
    }

    // MARK: - Connection

    func connect() throws {
        var connected = 0
        for path in dbPaths where FileManager.default.fileExists(atPath: path) {
            if dbQueues[path] == nil {
                var config = Configuration()
                config.readonly = true
                dbQueues[path] = try DatabaseQueue(path: path, configuration: config)
            }
            connected += 1
        }
        guard connected > 0 else {
            throw ReaderError.databaseNotFound(dbPaths.first ?? "")
        }
    }

    // MARK: - Cursor

    private static func decodeCursors(_ cursor: String?, defaultKey: String?) -> [String: Int64] {
        guard let cursor, !cursor.isEmpty else { return [:] }
        if let ms = Int64(cursor), let key = defaultKey {
            return [key: ms]
        }
        guard let data = cursor.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func encodeCursors(_ map: [String: Int64], singleKey: String?) -> String? {
        guard !map.isEmpty else { return nil }
        if let singleKey, map.count == 1, let val = map[singleKey] {
            return String(val)
        }
        guard let data = try? JSONEncoder().encode(map),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - Fetch Events

    /// Cursor is either a legacy epoch-ms string (single DB) or a JSON map of dbPath -> epoch-ms.
    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        guard !dbQueues.isEmpty else {
            return (events: [], newCursor: cursor)
        }

        let singleKey = dbPaths.count == 1 ? dbPaths.first : nil
        var cursorMap = Self.decodeCursors(cursor, defaultKey: singleKey ?? Self.defaultPath)
        var allEvents: [UsageEvent] = []

        for path in dbPaths {
            guard let queue = dbQueues[path] else { continue }
            let sinceMs = cursorMap[path]
            do {
                let (events, latestMs) = try queue.read { db in
                    try self.fetchFromDB(db, sinceMs: sinceMs)
                }
                allEvents.append(contentsOf: events)
                if let latestMs {
                    cursorMap[path] = latestMs
                }
            } catch {
                continue
            }
        }

        allEvents.sort { $0.observedAt < $1.observedAt }
        let newCursor = Self.encodeCursors(cursorMap, singleKey: singleKey) ?? cursor
        return (events: allEvents, newCursor: newCursor)
    }

    private func fetchFromDB(_ db: Database, sinceMs: Int64?) throws -> (events: [UsageEvent], latestMs: Int64?) {
        let isV2 = try db.tableExists("session_message") && db.tableExists("session_v2")
        // Assistant rows are inserted at stream start with `tokens = NULL` and updated when
        // the response finishes, so `time_updated` tracks when token counts become available.
        let sql: String
        if isV2 {
            // OpenCode 2.x schema: `session_message` + `session_v2`. `$.tokens.total` is not
            // written in v2; total is `input + output + reasoning + cache.read + cache.write`.
            sql = """
                SELECT
                    m.id AS message_id,
                    m.session_id,
                    m.time_created,
                    COALESCE(m.time_updated, m.time_created) AS cursor_ts,
                    s.title AS session_title,
                    s.directory AS session_directory,
                    p.name AS project_name,
                    p.worktree AS project_worktree,
                    COALESCE(json_extract(m.data, '$.model.id'), json_extract(m.data, '$.modelID')) AS model_id,
                    COALESCE(json_extract(m.data, '$.model.providerID'), json_extract(m.data, '$.providerID')) AS provider_id,
                    json_extract(m.data, '$.agent') AS agent,
                    json_extract(m.data, '$.tokens.total') AS tokens_total,
                    json_extract(m.data, '$.tokens.input') AS tokens_input,
                    json_extract(m.data, '$.tokens.output') AS tokens_output,
                    json_extract(m.data, '$.tokens.reasoning') AS tokens_reasoning,
                    json_extract(m.data, '$.tokens.cache.read') AS cache_read,
                    json_extract(m.data, '$.tokens.cache.write') AS cache_write,
                    json_extract(m.data, '$.cost') AS cost,
                    (SELECT json_extract(um.data, '$.text')
                     FROM session_message um
                     WHERE um.session_id = m.session_id
                       AND um.type = 'user'
                     ORDER BY um.time_created DESC LIMIT 1
                    ) AS last_prompt
                FROM session_message m
                JOIN session_v2 s ON m.session_id = s.id
                LEFT JOIN project p ON s.project_id = p.id
                WHERE m.type = 'assistant'
                  AND json_extract(m.data, '$.tokens') IS NOT NULL
                  \(sinceMs != nil ? "AND COALESCE(m.time_updated, m.time_created) > ?" : "")
                ORDER BY m.time_created ASC
                """
        } else {
            // OpenCode 1.x schema: `message` + `session` + `part`.
            sql = """
                SELECT
                    m.id AS message_id,
                    m.session_id,
                    m.time_created,
                    m.time_created AS cursor_ts,
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
                  \(sinceMs != nil ? "AND m.time_created > ?" : "")
                ORDER BY m.time_created ASC
                """
        }

        let arguments: StatementArguments = sinceMs.map { [$0] } ?? []
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)

        var events: [UsageEvent] = []
        var latestTimestamp: Int64?
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
            // On 1.x `total` is deliberately NOT recomputed from the components: on 11,323
            // post-patch rows OpenCode already reports `total < input + output` by up
            // to 93,890 tokens, so recomputing would inflate reported volume. On 2.x
            // `$.tokens.total` is absent so we sum the five components.
            let tokensInput: Int = max(0, row["tokens_input"] ?? 0)
            let tokensOutput: Int = max(0, row["tokens_output"] ?? 0)
            let tokensReasoning: Int = max(0, row["tokens_reasoning"] ?? 0)
            let cacheRead: Int = max(0, row["cache_read"] ?? 0)
            let cacheWrite: Int = max(0, row["cache_write"] ?? 0)
            let rawTotal: Int = max(0, row["tokens_total"] ?? 0)
            let tokensTotal: Int = rawTotal > 0
                ? rawTotal
                : (tokensInput + tokensOutput + tokensReasoning + cacheRead + cacheWrite)

            guard tokensTotal > 0 else { continue }

            let observedAt = Date(timeIntervalSince1970: Double(timeCreated) / 1000.0)

            // OpenCode's `tokens.input` is uncached input on cached turns, while
            // CostEstimator.estimateCostFromEvents expects `promptTokens` to be the
            // full prompt context (`input + cacheRead + cacheWrite`) and subtracts
            // `cacheRead + cacheWrite` internally.
            let reportedCost: Double = row["cost"] ?? 0.0
            let cost = Self.resolveCost(
                reportedCost: reportedCost,
                model: modelId,
                observedAt: observedAt,
                promptTokens: tokensInput + cacheRead + cacheWrite,
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
            let cursorTs: Int64 = row["cursor_ts"] ?? timeCreated
            if latestTimestamp == nil || cursorTs > latestTimestamp! {
                latestTimestamp = cursorTs
            }
        }

        return (events: events, latestMs: latestTimestamp)
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
        let existingPaths = dbPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existingPaths.isEmpty else {
            return SourceHealth(
                source: .opencode,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database not found at \(dbPaths.first ?? "")",
                eventCount: 0
            )
        }

        guard !dbQueues.isEmpty else {
            return SourceHealth(
                source: .opencode,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Not connected to database",
                eventCount: 0
            )
        }

        var latestDate: Date?
        var totalEvents = 0

        for path in existingPaths {
            guard let queue = dbQueues[path] else { continue }
            do {
                let (lastTime, count) = try queue.read { db -> (Date?, Int) in
                    let isV2 = try db.tableExists("session_message") && db.tableExists("session_v2")
                    let sql = isV2
                        ? """
                          SELECT
                              MAX(m.time_created) AS last_time,
                              COUNT(*) AS event_count
                          FROM session_message m
                          WHERE m.type = 'assistant'
                            AND json_extract(m.data, '$.tokens') IS NOT NULL
                          """
                        : """
                          SELECT
                              MAX(m.time_created) AS last_time,
                              COUNT(*) AS event_count
                          FROM message m
                          WHERE json_extract(m.data, '$.role') = 'assistant'
                            AND COALESCE(json_extract(m.data, '$.tokens.total'), 0) > 0
                          """
                    let row = try Row.fetchOne(db, sql: sql)
                    let lastTimeMs: Int64? = row?["last_time"]
                    let eventCount: Int = row?["event_count"] ?? 0
                    let lastDate = lastTimeMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                    return (lastDate, eventCount)
                }
                totalEvents += count
                if let lastTime, latestDate == nil || lastTime > latestDate! {
                    latestDate = lastTime
                }
            } catch {
                return SourceHealth(
                    source: .opencode,
                    isHealthy: false,
                    lastEventTime: latestDate,
                    errorMessage: "Database read error: \(error.localizedDescription)",
                    eventCount: totalEvents
                )
            }
        }

        return SourceHealth(
            source: .opencode,
            isHealthy: true,
            lastEventTime: latestDate,
            errorMessage: nil,
            eventCount: totalEvents
        )
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
