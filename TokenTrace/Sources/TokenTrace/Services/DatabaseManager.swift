import Foundation
import GRDB

// @unchecked Sendable: dbPool is write-once in setup() and DatabasePool is itself
// thread-safe Sendable; dbPath is immutable. Do not add mutable stored state.
final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private(set) var dbPool: DatabasePool!
    private let dbPath: String

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tokenTraceDir = appSupport.appendingPathComponent("TokenTrace")
        try? FileManager.default.createDirectory(at: tokenTraceDir, withIntermediateDirectories: true)
        dbPath = tokenTraceDir.appendingPathComponent("token-trace.db").path
    }

    init(path: String) {
        dbPath = path
    }

    func setup() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        dbPool = try DatabasePool(path: dbPath, configuration: config)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "usage_events") { t in
                t.column("id", .text).primaryKey()
                t.column("observedAt", .datetime).notNull().indexed()
                t.column("source", .text).notNull().indexed()
                t.column("sessionID", .text).indexed()
                t.column("requestID", .text)
                t.column("projectName", .text).indexed()
                t.column("repoPath", .text)
                t.column("provider", .text)
                t.column("model", .text).indexed()
                t.column("agent", .text)
                t.column("promptTokens", .integer).notNull().defaults(to: 0)
                t.column("completionTokens", .integer).notNull().defaults(to: 0)
                t.column("cachedReadTokens", .integer).notNull().defaults(to: 0)
                t.column("cachedWriteTokens", .integer).notNull().defaults(to: 0)
                t.column("reasoningTokens", .integer).notNull().defaults(to: 0)
                t.column("totalTokens", .integer).notNull().defaults(to: 0)
                t.column("estimatedCostUSD", .double).notNull().defaults(to: 0)
            }

            try db.create(index: "idx_events_source_date", on: "usage_events", columns: ["source", "observedAt"])
            try db.create(index: "idx_events_dedupe", on: "usage_events", columns: ["source", "sessionID", "requestID"], unique: false)

            try db.create(table: "source_cursors") { t in
                t.column("source", .text).primaryKey()
                t.column("lastCursor", .text)
                t.column("lastScanAt", .datetime)
            }
        }
        migrator.registerMigration("v2-session-title") { db in
            try db.alter(table: "usage_events") { t in
                t.add(column: "sessionTitle", .text)
            }
        }

        migrator.registerMigration("v3-last-prompt") { db in
            try db.alter(table: "usage_events") { t in
                t.add(column: "lastPrompt", .text)
            }
        }

        migrator.registerMigration("v4-fix-codex-timestamps") { db in
            // Superseded by v5 — kept as no-op so existing DBs that already ran it don't error
        }

        migrator.registerMigration("v5-codex-per-request") { db in
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'codex'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'codex'")
        }

        migrator.registerMigration("v6-codex-live-sessions") { db in
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'codex'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'codex'")
        }

        migrator.registerMigration("v7-roo-per-task") { db in
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'roo'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'roo'")
        }

        migrator.registerMigration("v8-roo-snapshots") { db in
            try db.create(table: "roo_task_snapshot") { t in
                t.column("taskID", .text).primaryKey()
                t.column("lastTokensIn", .integer).notNull().defaults(to: 0)
                t.column("lastTokensOut", .integer).notNull().defaults(to: 0)
                t.column("lastCacheWrites", .integer).notNull().defaults(to: 0)
                t.column("lastCacheReads", .integer).notNull().defaults(to: 0)
                t.column("lastCost", .double).notNull().defaults(to: 0)
                t.column("lastTs", .integer).notNull().defaults(to: 0)
                t.column("lastStatus", .text)
                t.column("firstSeenAt", .datetime).notNull()
            }
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'roo'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'roo'")
        }

        // v9: adds newInputTokens (reset-aware positive delta of promptTokens within a
        // session = unique-work basis; promptTokens stays the full re-sent context =
        // cost basis), backfills it, and re-ingests codex for the reasoning keystone fix.
        migrator.registerMigration("v9-unique-work") { db in
            try db.alter(table: "usage_events") { t in
                t.add(column: "newInputTokens", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "session_input_state") { t in
                t.column("source", .text).notNull()
                t.column("sessionID", .text).notNull()
                t.column("lastPromptTokens", .integer).notNull().defaults(to: 0)
                t.column("lastObservedAt", .datetime)
                t.primaryKey(["source", "sessionID"])
            }

            // Reset-aware delta: first turn in a session, or any turn where promptTokens
            // dropped below the previous (context compaction / sub-conversation reset),
            // counts full promptTokens; otherwise the positive delta. Window functions
            // require SQLite 3.25+ (macOS 14+).
            try db.execute(sql: """
                WITH ordered AS (
                    SELECT id,
                           promptTokens AS p,
                           LAG(promptTokens) OVER (
                               PARTITION BY source, sessionID
                               ORDER BY observedAt, id
                           ) AS prev
                    FROM usage_events
                    WHERE source IN ('opencode', 'openclaw') AND sessionID IS NOT NULL
                )
                UPDATE usage_events
                SET newInputTokens = (
                    SELECT CASE
                               WHEN o.prev IS NULL OR o.p < o.prev THEN o.p
                               ELSE o.p - o.prev
                           END
                    FROM ordered o
                    WHERE o.id = usage_events.id
                )
                WHERE id IN (SELECT id FROM ordered)
                """)

            // Session-less rows (continue) each stand alone: all input is new.
            try db.execute(sql: """
                UPDATE usage_events
                SET newInputTokens = promptTokens
                WHERE sessionID IS NULL
                """)

            // Re-ingest codex from on-disk rollout JSONL so the reasoning keystone fix
            // applies; clearing the cursor forces a full re-scan on next collect.
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'codex'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'codex'")

            // Seed the live delta cursor from the latest promptTokens per session so the
            // next turn deltas against the true last value instead of restarting at zero.
            try db.execute(sql: """
                INSERT INTO session_input_state (source, sessionID, lastPromptTokens, lastObservedAt)
                SELECT e.source, e.sessionID, e.promptTokens, e.observedAt
                FROM usage_events e
                JOIN (
                    SELECT source, sessionID, MAX(observedAt) AS maxObservedAt
                    FROM usage_events
                    WHERE sessionID IS NOT NULL
                    GROUP BY source, sessionID
                ) latest
                  ON e.source = latest.source
                 AND e.sessionID = latest.sessionID
                 AND e.observedAt = latest.maxObservedAt
                """)
        }

        // v10: OpenCodeReader previously recorded projectName="/" and repoPath="/" for the
        // ~1,145 sessions attached to OpenCode's synthetic 'global' project row, stored
        // cost=0 for the ~26K assistant messages OpenCode itself never priced, and copied
        // through OpenCode's negative `tokens.output` on 1,786 messages. All three are
        // recomputed on read, so drop the opencode rows and its cursor to force a full
        // re-ingest; session_input_state must go too or the reset-aware newInputTokens
        // delta would start from stale prompt totals.
        migrator.registerMigration("v10-opencode-project-cost-and-tokens") { db in
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'opencode'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'opencode'")
            try db.execute(sql: "DELETE FROM session_input_state WHERE source = 'opencode'")
        }

        // v11: When provider prompt caching is active (`cachedReadTokens + cachedWriteTokens > 0`),
        // OpenCode's `tokens.input` (stored in `promptTokens`) is already the uncached new input
        // for that turn while `cachedReadTokens` holds the re-sent prefix. Applying a turn-to-turn
        // delta on `promptTokens` across cached turns treated any turn whose uncached input exceeded
        // the first turn's uncached input as a reset, or subtracted two uncached deltas. Repair
        // existing cached rows so `newInputTokens = promptTokens` and re-seed `session_input_state`.
        migrator.registerMigration("v11-cached-turn-new-input") { db in
            try db.execute(sql: """
                UPDATE usage_events
                SET newInputTokens = promptTokens
                WHERE source != 'codex' AND (cachedReadTokens + cachedWriteTokens) > 0
                """)
            try db.execute(sql: "DELETE FROM session_input_state")
            try db.execute(sql: """
                INSERT INTO session_input_state (source, sessionID, lastPromptTokens, lastObservedAt)
                SELECT e.source,
                       e.sessionID,
                       CASE WHEN e.source = 'codex' THEN e.promptTokens
                            ELSE e.promptTokens + e.cachedReadTokens + e.cachedWriteTokens
                       END,
                       e.observedAt
                FROM usage_events e
                JOIN (
                    SELECT source, sessionID, MAX(observedAt) AS maxObservedAt
                    FROM usage_events
                    WHERE sessionID IS NOT NULL
                    GROUP BY source, sessionID
                ) latest
                  ON e.source = latest.source
                 AND e.sessionID = latest.sessionID
                 AND e.observedAt = latest.maxObservedAt
                GROUP BY e.source, e.sessionID
                """)
        }

        // v12: Repair Codex newInputTokens where v11 set newInputTokens = promptTokens on cached
        // Codex turns (Codex's input_tokens includes cached_input_tokens, unlike OpenCode/Hermes).
        migrator.registerMigration("v12-codex-cached-new-input-fix") { db in
            try db.execute(sql: """
                WITH ordered AS (
                    SELECT id,
                           CASE
                               WHEN LAG(promptTokens) OVER (
                                        PARTITION BY source, sessionID
                                        ORDER BY observedAt, id
                                    ) IS NULL
                                 OR promptTokens < LAG(promptTokens) OVER (
                                        PARTITION BY source, sessionID
                                        ORDER BY observedAt, id
                                    )
                               THEN promptTokens
                               ELSE promptTokens - LAG(promptTokens) OVER (
                                        PARTITION BY source, sessionID
                                        ORDER BY observedAt, id
                                    )
                           END AS delta
                    FROM usage_events
                    WHERE source = 'codex' AND sessionID IS NOT NULL
                )
                UPDATE usage_events
                SET newInputTokens = ordered.delta
                FROM ordered
                WHERE usage_events.id = ordered.id
                """)
            try db.execute(sql: "DELETE FROM session_input_state WHERE source = 'codex'")
            try db.execute(sql: """
                INSERT INTO session_input_state (source, sessionID, lastPromptTokens, lastObservedAt)
                SELECT e.source, e.sessionID, e.promptTokens, e.observedAt
                FROM usage_events e
                JOIN (
                    SELECT source, sessionID, MAX(observedAt) AS maxObservedAt
                    FROM usage_events
                    WHERE source = 'codex' AND sessionID IS NOT NULL
                    GROUP BY source, sessionID
                ) latest
                  ON e.source = latest.source
                 AND e.sessionID = latest.sessionID
                 AND e.observedAt = latest.maxObservedAt
                GROUP BY e.source, e.sessionID
                """)
        }

        return migrator
    }

    // MARK: - Insert

    /// A full re-ingest after a wipe migration hands us ~120K events at once; in one
    /// transaction that measured a 1.19 GB peak footprint in a menu-bar app. Events must
    /// stay in ascending observedAt order so the newInputTokens delta chain is unaffected
    /// by where a chunk boundary falls.
    private static let insertChunkSize = 5_000

    func insertEvents(_ events: [UsageEvent]) async throws {
        // Chunks are separate transactions, so a mid-way failure leaves earlier chunks
        // committed. That is safe: the caller only advances the cursor after a clean
        // return, and `save` is an upsert on the primary key, so a retry re-applies the
        // remainder without duplicating anything.
        var index = events.startIndex
        while index < events.endIndex {
            let end = min(index + Self.insertChunkSize, events.endIndex)
            try await insertChunk(Array(events[index..<end]))
            index = end
        }
    }

    private func insertChunk(_ events: [UsageEvent]) async throws {
        try await dbPool.write { db in
            // Batch prior-state lookup (was N+1). Map is updated in-loop so repeated turns
            // of one session within a batch chain deltas exactly as the per-event query did.
            var lastPromptBySession = try Self.fetchLastPromptTokens(for: events, in: db)
            for event in events {
                var event = Self.clampTokenCounts(event)
                event.newInputTokens = Self.computeNewInputTokens(for: event, lastPrompt: event.sessionID.flatMap { lastPromptBySession[SessionKey(source: event.source.rawValue, sessionID: $0)] })
                try event.save(db)
                if let sessionID = event.sessionID {
                    let contextPrompt = event.source == .codex
                        ? event.promptTokens
                        : (event.promptTokens + event.cachedReadTokens + event.cachedWriteTokens)
                    try db.execute(sql: """
                        INSERT INTO session_input_state (source, sessionID, lastPromptTokens, lastObservedAt)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(source, sessionID) DO UPDATE SET
                            lastPromptTokens = excluded.lastPromptTokens,
                            lastObservedAt = excluded.lastObservedAt
                        """, arguments: [event.source.rawValue, sessionID, contextPrompt, event.observedAt])
                    lastPromptBySession[SessionKey(source: event.source.rawValue, sessionID: sessionID)] = contextPrompt
                }
            }
        }
    }

    /// Structural floor for every writer. OpenCode is known to emit negative
    /// `tokens.output` and ContinueReader/OpenclawReader forward provider counts
    /// unchecked, and a single negative value corrupts every downstream SUM.
    /// Semantic repair still belongs in each reader; this is only the last line.
    private static func clampTokenCounts(_ event: UsageEvent) -> UsageEvent {
        var event = event
        event.promptTokens = max(0, event.promptTokens)
        event.completionTokens = max(0, event.completionTokens)
        event.cachedReadTokens = max(0, event.cachedReadTokens)
        event.cachedWriteTokens = max(0, event.cachedWriteTokens)
        event.reasoningTokens = max(0, event.reasoningTokens)
        event.totalTokens = max(0, event.totalTokens)
        event.estimatedCostUSD = max(0, event.estimatedCostUSD)
        return event
    }

    private struct SessionKey: Hashable {
        let source: String
        let sessionID: String
    }

    private static func fetchLastPromptTokens(for events: [UsageEvent], in db: Database) throws -> [SessionKey: Int] {
        let keys = Set(events.compactMap { event in event.sessionID.map { SessionKey(source: event.source.rawValue, sessionID: $0) } })
        guard !keys.isEmpty else { return [:] }
        var result: [SessionKey: Int] = [:]
        // Group sessionIDs by source so each source uses one IN(?) query.
        let sessionIDsBySource = Dictionary(grouping: keys, by: { $0.source }).mapValues { keyList in keyList.map(\.sessionID) }
        for (source, sessionIDs) in sessionIDsBySource {
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionID, lastPromptTokens FROM session_input_state
                WHERE source = ? AND sessionID IN (\(placeholders))
                """, arguments: StatementArguments([source] + sessionIDs))
            for row in rows {
                let sessionID: String = row["sessionID"]
                result[SessionKey(source: source, sessionID: sessionID)] = row["lastPromptTokens"]
            }
        }
        return result
    }

    // Reset-aware positive delta of promptTokens within a (source, sessionID): a turn
    // whose prompt dropped below the last seen value (context compaction) or that opens
    // a session counts its full prompt as new; otherwise only the growth is new. When
    // provider prompt caching is active (`cachedReadTokens + cachedWriteTokens > 0`),
    // `promptTokens` is already the uncached new input for that turn.
    private static func computeNewInputTokens(for event: UsageEvent, lastPrompt previous: Int?) -> Int {
        guard event.sessionID != nil else { return event.promptTokens }
        if event.source != .codex && (event.cachedReadTokens + event.cachedWriteTokens > 0) {
            return event.promptTokens
        }
        guard let prev = previous, event.promptTokens >= prev else { return event.promptTokens }
        return event.promptTokens - prev
    }

    // MARK: - Queries

    func todaySummary() async throws -> (total: Int, prompt: Int, newInput: Int, completion: Int, cached: Int, reasoning: Int, cachedRead: Int, cachedWrite: Int, estimatedCost: Double, bySource: [UsageEvent.Source: Int]) {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source,
                       COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(newInputTokens), 0) as newInput,
                       COALESCE(SUM(completionTokens), 0) as completion,
                       COALESCE(SUM(cachedReadTokens), 0) as cachedRead,
                       COALESCE(SUM(cachedWriteTokens), 0) as cachedWrite,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cached,
                       COALESCE(SUM(reasoningTokens), 0) as reasoning,
                       COALESCE(SUM(estimatedCostUSD), 0) as cost
                FROM usage_events WHERE observedAt >= ?
                GROUP BY source
                """, arguments: [startOfDay])

            var totalAll = 0, promptAll = 0, newInputAll = 0, completionAll = 0, cachedAll = 0, reasoningAll = 0
            var cachedReadAll = 0, cachedWriteAll = 0, costAll = 0.0
            var bySource: [UsageEvent.Source: Int] = [:]

            for row in rows {
                let source = UsageEvent.Source(rawValue: row["source"] as String) ?? .opencode
                let total: Int = row["total"]
                totalAll += total
                promptAll += row["prompt"]
                newInputAll += row["newInput"] as Int
                completionAll += row["completion"]
                cachedAll += row["cached"]
                reasoningAll += row["reasoning"]
                cachedReadAll += row["cachedRead"] as Int
                cachedWriteAll += row["cachedWrite"] as Int
                costAll += row["cost"] as Double
                bySource[source] = total
            }

            return (totalAll, promptAll, newInputAll, completionAll, cachedAll, reasoningAll, cachedReadAll, cachedWriteAll, costAll, bySource)
        }
    }

    func recentSessions(limit: Int = 10) async throws -> [SessionSummary] {
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.sessionID, e.source, e.projectName, e.model, e.agent, e.sessionTitle,
                       COALESCE(SUM(e.totalTokens), 0) as totalTokens,
                       COALESCE(SUM(e.promptTokens), 0) as promptTokens,
                       COALESCE(SUM(e.newInputTokens), 0) as newInputTokens,
                       COALESCE(SUM(e.completionTokens), 0) as completionTokens,
                       COALESCE(SUM(e.cachedReadTokens) + SUM(e.cachedWriteTokens), 0) as cachedTokens,
                       COALESCE(SUM(e.reasoningTokens), 0) as reasoningTokens,
                       COALESCE(SUM(e.cachedReadTokens), 0) as cachedReadTokens,
                       COALESCE(SUM(e.cachedWriteTokens), 0) as cachedWriteTokens,
                       COALESCE(SUM(e.estimatedCostUSD), 0) as estimatedCostUSD,
                       COUNT(*) as eventCount,
                       MIN(e.observedAt) as firstSeen,
                       MAX(e.observedAt) as lastSeen,
                       (SELECT lp.lastPrompt FROM usage_events lp
                        WHERE lp.sessionID = e.sessionID AND lp.lastPrompt IS NOT NULL
                        ORDER BY lp.observedAt DESC LIMIT 1) as lastPrompt
                FROM usage_events e WHERE e.sessionID IS NOT NULL
                GROUP BY e.sessionID ORDER BY lastSeen DESC LIMIT ?
                """, arguments: [limit])

            return rows.map { row in
                SessionSummary(
                    id: row["sessionID"],
                    source: UsageEvent.Source(rawValue: row["source"] as String) ?? .opencode,
                    title: row["sessionTitle"],
                    projectName: row["projectName"],
                    model: row["model"],
                    agent: row["agent"],
                    totalTokens: row["totalTokens"],
                    promptTokens: row["promptTokens"],
                    newInputTokens: row["newInputTokens"],
                    completionTokens: row["completionTokens"],
                    cachedTokens: row["cachedTokens"],
                    reasoningTokens: row["reasoningTokens"],
                    cachedReadTokens: row["cachedReadTokens"],
                    cachedWriteTokens: row["cachedWriteTokens"],
                    estimatedCostUSD: row["estimatedCostUSD"],
                    eventCount: row["eventCount"],
                    firstSeen: row["firstSeen"],
                    lastSeen: row["lastSeen"],
                    lastPrompt: row["lastPrompt"]
                )
            }
        }
    }

    // MARK: - Daily History

    // Reused across all dailySummaries calls — DateFormatter is expensive to allocate.
    private static let dailySummaryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // chartData parses period keys as local midnight; POSIX locale keeps parsing stable.
    private static let chartDataFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Calendar.current.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func dailySummaries(days: Int = 14) async throws -> [DailySummary] {
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(observedAt) as day,
                       COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(newInputTokens), 0) as newInput,
                       COALESCE(SUM(completionTokens), 0) as completion,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cached,
                       COALESCE(SUM(reasoningTokens), 0) as reasoning,
                       COALESCE(SUM(cachedReadTokens), 0) as cachedRead,
                       COALESCE(SUM(cachedWriteTokens), 0) as cachedWrite,
                       COALESCE(SUM(estimatedCostUSD), 0) as cost,
                       COUNT(DISTINCT sessionID) as sessionCount
                FROM usage_events
                WHERE observedAt >= date('now', '-\(days) days')
                GROUP BY date(observedAt)
                ORDER BY day DESC
                """)

            return rows.compactMap { row -> DailySummary? in
                guard let dayString: String = row["day"] else { return nil }
                guard let date = Self.dailySummaryFormatter.date(from: dayString) else { return nil }
                return DailySummary(
                    date: date,
                    totalTokens: row["total"],
                    promptTokens: row["prompt"],
                    newInputTokens: row["newInput"],
                    completionTokens: row["completion"],
                    cachedTokens: row["cached"],
                    reasoningTokens: row["reasoning"],
                    sessionCount: row["sessionCount"],
                    cachedReadTokens: row["cachedRead"],
                    cachedWriteTokens: row["cachedWrite"],
                    estimatedCostUSD: row["cost"]
                )
            }
        }
    }

    func sourceTotalsForDate(_ date: Date) async throws -> [UsageEvent.Source: Int] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COALESCE(SUM(totalTokens), 0) as total
                FROM usage_events
                WHERE observedAt >= ? AND observedAt < ?
                GROUP BY source
                """, arguments: [startOfDay, endOfDay])

            var result: [UsageEvent.Source: Int] = [:]
            for row in rows {
                if let source = UsageEvent.Source(rawValue: row["source"] as String) {
                    result[source] = row["total"]
                }
            }
            return result
        }
    }

    func sessionsForDate(_ date: Date) async throws -> [SessionSummary] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.sessionID, e.source, e.projectName, e.model, e.agent, e.sessionTitle,
                       COALESCE(SUM(e.totalTokens), 0) as totalTokens,
                       COALESCE(SUM(e.promptTokens), 0) as promptTokens,
                       COALESCE(SUM(e.newInputTokens), 0) as newInputTokens,
                       COALESCE(SUM(e.completionTokens), 0) as completionTokens,
                       COALESCE(SUM(e.cachedReadTokens) + SUM(e.cachedWriteTokens), 0) as cachedTokens,
                       COALESCE(SUM(e.reasoningTokens), 0) as reasoningTokens,
                       COALESCE(SUM(e.cachedReadTokens), 0) as cachedReadTokens,
                       COALESCE(SUM(e.cachedWriteTokens), 0) as cachedWriteTokens,
                       COALESCE(SUM(e.estimatedCostUSD), 0) as estimatedCostUSD,
                       COUNT(*) as eventCount,
                       MIN(e.observedAt) as firstSeen,
                       MAX(e.observedAt) as lastSeen,
                       (SELECT lp.lastPrompt FROM usage_events lp
                        WHERE lp.sessionID = e.sessionID AND lp.lastPrompt IS NOT NULL
                        ORDER BY lp.observedAt DESC LIMIT 1) as lastPrompt
                FROM usage_events e
                WHERE e.sessionID IS NOT NULL
                  AND e.observedAt >= ? AND e.observedAt < ?
                GROUP BY e.sessionID ORDER BY lastSeen DESC
                """, arguments: [startOfDay, endOfDay])

            return rows.map { row in
                SessionSummary(
                    id: row["sessionID"],
                    source: UsageEvent.Source(rawValue: row["source"] as String) ?? .opencode,
                    title: row["sessionTitle"],
                    projectName: row["projectName"],
                    model: row["model"],
                    agent: row["agent"],
                    totalTokens: row["totalTokens"],
                    promptTokens: row["promptTokens"],
                    newInputTokens: row["newInputTokens"],
                    completionTokens: row["completionTokens"],
                    cachedTokens: row["cachedTokens"],
                    reasoningTokens: row["reasoningTokens"],
                    cachedReadTokens: row["cachedReadTokens"],
                    cachedWriteTokens: row["cachedWriteTokens"],
                    estimatedCostUSD: row["estimatedCostUSD"],
                    eventCount: row["eventCount"],
                    firstSeen: row["firstSeen"],
                    lastSeen: row["lastSeen"],
                    lastPrompt: row["lastPrompt"]
                )
            }
        }
    }

    // MARK: - Chart Data

    func chartData(range: ChartRange) async throws -> [ChartDataPoint] {
        return try await dbPool.read { db in
            // observedAt is UTC; bucket in localtime so Swift Charts (which re-bins
            // BarMark via local Calendar.current) agrees. Anchoring the X position to
            // MIN(observedAt) instead let an event like 2026-04-01 00:23 UTC fall into
            // 2026-03-31 locally, drawing April's bar on top of March's.
            let whereClause: String
            let periodExpr: String

            switch range {
            case .week:
                whereClause = "WHERE observedAt >= date('now', '-7 days')"
                periodExpr = "date(observedAt, 'localtime')"
            case .month:
                whereClause = "WHERE observedAt >= date('now', '-30 days')"
                periodExpr = "date(observedAt, 'localtime')"
            case .year:
                whereClause = "WHERE observedAt >= date('now', '-365 days')"
                // Sunday-anchored week start, computed in local time.
                periodExpr = "date(observedAt, 'localtime', '-' || strftime('%w', observedAt, 'localtime') || ' days')"
            case .total:
                whereClause = ""
                periodExpr = "strftime('%Y-%m-01', observedAt, 'localtime')"
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT \(periodExpr) as period,
                       COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(newInputTokens), 0) as newInput,
                       COALESCE(SUM(completionTokens), 0) as completion
                FROM usage_events
                \(whereClause)
                GROUP BY period
                ORDER BY period ASC
                """)

            return rows.compactMap { row -> ChartDataPoint? in
                guard let periodKey: String = row["period"],
                      let date = Self.chartDataFormatter.date(from: periodKey) else { return nil }
                return ChartDataPoint(
                    date: date,
                    totalTokens: row["total"],
                    promptTokens: row["prompt"],
                    newInputTokens: row["newInput"],
                    completionTokens: row["completion"],
                    label: periodKey
                )
            }
        }
    }

    func rangeSummary(range: ChartRange) async throws -> (total: Int, prompt: Int, newInput: Int, completion: Int, cached: Int, reasoning: Int, cachedRead: Int, cachedWrite: Int, estimatedCost: Double) {
        return try await dbPool.read { db in
            let whereClause: String
            if let days = range.days {
                whereClause = "WHERE observedAt >= date('now', '-\(days) days')"
            } else {
                whereClause = ""
            }

            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(newInputTokens), 0) as newInput,
                       COALESCE(SUM(completionTokens), 0) as completion,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cached,
                       COALESCE(SUM(reasoningTokens), 0) as reasoning,
                       COALESCE(SUM(cachedReadTokens), 0) as cachedRead,
                       COALESCE(SUM(cachedWriteTokens), 0) as cachedWrite,
                       COALESCE(SUM(estimatedCostUSD), 0) as cost
                FROM usage_events
                \(whereClause)
                """)

            guard let row = row else { return (0, 0, 0, 0, 0, 0, 0, 0, 0.0) }
            return (row["total"], row["prompt"], row["newInput"], row["completion"], row["cached"], row["reasoning"], row["cachedRead"], row["cachedWrite"], row["cost"])
        }
    }

    // MARK: - Cursor Management

    func getCursor(for source: UsageEvent.Source) async throws -> String? {
        try await getCursor(forKey: source.rawValue)
    }

    func setCursor(for source: UsageEvent.Source, cursor: String) async throws {
        try await setCursor(forKey: source.rawValue, cursor: cursor)
    }

    func getCursor(forKey key: String) async throws -> String? {
        return try await dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT lastCursor FROM source_cursors WHERE source = ?", arguments: [key])?["lastCursor"]
        }
    }

    func setCursor(forKey key: String, cursor: String) async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO source_cursors (source, lastCursor, lastScanAt) VALUES (?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET lastCursor = excluded.lastCursor, lastScanAt = excluded.lastScanAt
                """, arguments: [key, cursor, Date()])
        }
    }
}
