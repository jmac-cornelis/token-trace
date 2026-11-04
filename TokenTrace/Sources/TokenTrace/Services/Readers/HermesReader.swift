import Foundation
import GRDB

// MARK: - HermesReader

/// Reads token usage from Hermes Agent SQLite databases (`state.db` and
/// `profiles/*/state.db` under `~/.hermes`, plus any synced remote profile DBs).
///
/// Hermes stores cumulative per-(session, model, provider, task) counters in
/// `session_model_usage` where `input_tokens` is uncached input, `cache_read_tokens`
/// and `cache_write_tokens` are separate buckets, and total prompt context is
/// `input_tokens + cache_read_tokens + cache_write_tokens`.
final class HermesReader {

    // MARK: - Properties

    private let hermesRootPaths: [String]
    private var dbQueues: [String: DatabaseQueue] = [:]

    static let defaultRootPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [String] = []
        if let envHome = ProcessInfo.processInfo.environment["HERMES_HOME"], !envHome.isEmpty {
            roots.append(envHome)
        }
        roots.append("\(home)/.hermes")
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }()

    // MARK: - Initialization

    init(hermesRootPaths: [String] = HermesReader.defaultRootPaths) {
        self.hermesRootPaths = hermesRootPaths
    }

    init(dbPath: String) {
        self.hermesRootPaths = [dbPath]
    }

    // MARK: - Discovery & Connection

    func discoverDatabasePaths() -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        for root in hermesRootPaths {
            if root.hasSuffix(".db") || root.hasSuffix(".sqlite") {
                if fm.fileExists(atPath: root) {
                    found.append(root)
                }
                continue
            }

            let rootDB = (root as NSString).appendingPathComponent("state.db")
            if fm.fileExists(atPath: rootDB) {
                found.append(rootDB)
            }

            let profilesDir = (root as NSString).appendingPathComponent("profiles")
            if let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) {
                for profile in profiles.sorted() {
                    let profileDB = (profilesDir as NSString)
                        .appendingPathComponent(profile)
                        .appending("/state.db")
                    if fm.fileExists(atPath: profileDB) {
                        found.append(profileDB)
                    }
                }
            }
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    func connect() throws {
        let paths = discoverDatabasePaths()
        guard !paths.isEmpty else {
            throw ReaderError.databaseNotFound(hermesRootPaths.first ?? "~/.hermes/state.db")
        }

        for path in paths where dbQueues[path] == nil {
            var config = Configuration()
            config.readonly = true
            dbQueues[path] = try DatabaseQueue(path: path, configuration: config)
        }
    }

    // MARK: - Cursor

    private static func decodeCursors(_ cursor: String?) -> [String: Double] {
        guard let cursor, !cursor.isEmpty,
              let data = cursor.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func encodeCursors(_ map: [String: Double]) -> String? {
        guard !map.isEmpty,
              let data = try? JSONEncoder().encode(map),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - Fetch Events

    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        let paths = discoverDatabasePaths()
        guard !paths.isEmpty else {
            return (events: [], newCursor: cursor)
        }

        var cursorMap = Self.decodeCursors(cursor)
        var allEvents: [UsageEvent] = []

        for path in paths {
            let queue: DatabaseQueue
            if let existing = dbQueues[path] {
                queue = existing
            } else {
                var config = Configuration()
                config.readonly = true
                guard let created = try? DatabaseQueue(path: path, configuration: config) else {
                    continue
                }
                dbQueues[path] = created
                queue = created
            }

            let sinceTime = cursorMap[path] ?? 0
            let profileFallback = Self.inferredProfileName(from: path)

            do {
                let (events, maxSeen) = try queue.read { db in
                    try self.fetchFromDB(db, dbPath: path, profileFallback: profileFallback, sinceTime: sinceTime)
                }
                allEvents.append(contentsOf: events)
                if let maxSeen, maxSeen > sinceTime {
                    cursorMap[path] = maxSeen
                }
            } catch {
                continue
            }
        }

        allEvents.sort { $0.observedAt < $1.observedAt }
        let newCursor = Self.encodeCursors(cursorMap) ?? cursor
        return (events: allEvents, newCursor: newCursor)
    }

    private func fetchFromDB(
        _ db: Database,
        dbPath: String,
        profileFallback: String?,
        sinceTime: Double
    ) throws -> (events: [UsageEvent], maxSeen: Double?) {
        guard try db.tableExists("sessions") else {
            return ([], nil)
        }

        let hasModelUsage = try db.tableExists("session_model_usage")
        let hasMessages = try db.tableExists("messages")
        let lastPromptSubquery = hasMessages
            ? """
              (SELECT m.content FROM messages m
               WHERE m.session_id = s.id AND m.role = 'user' AND m.content IS NOT NULL
               ORDER BY m.timestamp DESC LIMIT 1)
              """
            : "NULL"

        var events: [UsageEvent] = []
        var maxSeen: Double?

        if hasModelUsage {
            let sql = """
                SELECT
                    u.session_id,
                    u.model AS usage_model,
                    u.billing_provider AS usage_provider,
                    u.task AS usage_task,
                    u.api_call_count,
                    u.input_tokens,
                    u.output_tokens,
                    u.cache_read_tokens,
                    u.cache_write_tokens,
                    u.reasoning_tokens,
                    u.estimated_cost_usd AS usage_estimated_cost,
                    u.actual_cost_usd AS usage_actual_cost,
                    COALESCE(u.last_seen, s.last_activity_at, s.started_at) AS event_ts,
                    s.title AS session_title,
                    s.cwd AS session_cwd,
                    s.git_repo_root AS session_repo_root,
                    s.profile_name AS session_profile,
                    s.source AS session_source,
                    \(lastPromptSubquery) AS last_prompt
                FROM session_model_usage u
                JOIN sessions s ON s.id = u.session_id
                WHERE (COALESCE(u.input_tokens, 0) + COALESCE(u.output_tokens, 0) +
                       COALESCE(u.cache_read_tokens, 0) + COALESCE(u.cache_write_tokens, 0) +
                       COALESCE(u.reasoning_tokens, 0)) > 0
                  AND COALESCE(u.last_seen, s.last_activity_at, s.started_at, 0) > ?
                ORDER BY event_ts ASC
                """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [sinceTime])
            for row in rows {
                let sessionId: String = row["session_id"]
                let model: String? = row["usage_model"]
                let provider: String? = row["usage_provider"]
                let task: String = row["usage_task"] ?? ""
                let inputTokens: Int = max(0, row["input_tokens"] ?? 0)
                let outputTokens: Int = max(0, row["output_tokens"] ?? 0)
                let cacheRead: Int = max(0, row["cache_read_tokens"] ?? 0)
                let cacheWrite: Int = max(0, row["cache_write_tokens"] ?? 0)
                let reasoning: Int = max(0, row["reasoning_tokens"] ?? 0)
                let promptTokens = inputTokens + cacheRead + cacheWrite
                let totalTokens = promptTokens + outputTokens + reasoning
                guard totalTokens > 0 else { continue }

                let eventTs: Double = row["event_ts"] ?? Date().timeIntervalSince1970
                let observedAt = Date(timeIntervalSince1970: eventTs)
                if maxSeen == nil || eventTs > maxSeen! {
                    maxSeen = eventTs
                }

                let actualCost: Double = row["usage_actual_cost"] ?? 0.0
                let estCost: Double = row["usage_estimated_cost"] ?? 0.0
                let reportedCost = actualCost > 0 ? actualCost : estCost
                let cost = OpenCodeReader.resolveCost(
                    reportedCost: reportedCost,
                    model: model,
                    observedAt: observedAt,
                    promptTokens: promptTokens,
                    completionTokens: outputTokens,
                    cachedReadTokens: cacheRead,
                    cachedWriteTokens: cacheWrite,
                    reasoningTokens: reasoning
                )

                let repoPath = OpenCodeReader.resolveRepoPath(
                    worktree: row["session_repo_root"] as String?,
                    sessionDirectory: row["session_cwd"] as String?
                )
                let projectName = OpenCodeReader.resolveProjectName(
                    projectName: nil,
                    repoPath: repoPath
                )

                let profile: String? = (row["session_profile"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? profileFallback
                let agentLabel: String?
                if !task.isEmpty, let profile {
                    agentLabel = "\(profile):\(task)"
                } else if !task.isEmpty {
                    agentLabel = task
                } else {
                    agentLabel = profile ?? (row["session_source"] as String?)
                }

                let profileTag = profile ?? "default"
                let modelTag = model ?? "unknown"
                let taskTag = task.isEmpty ? "main" : task
                let eventId = "hermes-\(profileTag)-\(sessionId)-\(modelTag)-\(taskTag)"

                let event = UsageEvent(
                    id: eventId,
                    observedAt: observedAt,
                    source: .hermes,
                    sessionID: "hermes-\(profileTag)-\(sessionId)",
                    sessionTitle: row["session_title"],
                    requestID: eventId,
                    projectName: projectName ?? profile,
                    repoPath: repoPath,
                    provider: (provider?.isEmpty == false) ? provider : "cornelis",
                    model: model,
                    agent: agentLabel,
                    promptTokens: inputTokens,
                    completionTokens: outputTokens,
                    cachedReadTokens: cacheRead,
                    cachedWriteTokens: cacheWrite,
                    reasoningTokens: reasoning,
                    totalTokens: totalTokens,
                    estimatedCostUSD: cost,
                    lastPrompt: row["last_prompt"]
                )
                events.append(event)
            }
        }

        return (events: events, maxSeen: maxSeen)
    }

    // MARK: - Health Check

    func healthCheck() -> SourceHealth {
        let paths = discoverDatabasePaths()
        guard !paths.isEmpty else {
            return SourceHealth(
                source: .hermes,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "No Hermes databases found",
                eventCount: 0
            )
        }

        var latestDate: Date?
        var totalSessions = 0

        for path in paths {
            guard let queue = dbQueues[path] else { continue }
            do {
                let (lastTime, count) = try queue.read { db -> (Date?, Int) in
                    guard try db.tableExists("sessions") else { return (nil, 0) }
                    let row = try Row.fetchOne(db, sql: """
                        SELECT
                            MAX(COALESCE(last_activity_at, started_at)) AS last_time,
                            COUNT(*) AS session_count
                        FROM sessions
                        WHERE (COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0) +
                               COALESCE(cache_read_tokens, 0) + COALESCE(cache_write_tokens, 0) +
                               COALESCE(reasoning_tokens, 0)) > 0
                        """)
                    let ts: Double? = row?["last_time"]
                    let cnt: Int = row?["session_count"] ?? 0
                    return (ts.map { Date(timeIntervalSince1970: $0) }, cnt)
                }
                totalSessions += count
                if let lastTime, latestDate == nil || lastTime > latestDate! {
                    latestDate = lastTime
                }
            } catch {
                continue
            }
        }

        return SourceHealth(
            source: .hermes,
            isHealthy: true,
            lastEventTime: latestDate,
            errorMessage: nil,
            eventCount: totalSessions
        )
    }

    private static func inferredProfileName(from dbPath: String) -> String? {
        let components = (dbPath as NSString).pathComponents
        if let idx = components.lastIndex(of: "profiles"), idx + 1 < components.count - 1 {
            return components[idx + 1]
        }
        return nil
    }
}
