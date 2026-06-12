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

        return migrator
    }

    // MARK: - Insert

    func insertEvents(_ events: [UsageEvent]) async throws {
        try await dbPool.write { db in
            for event in events {
                var event = event
                event.newInputTokens = try Self.computeNewInputTokens(for: event, in: db)
                try event.save(db)
                if let sessionID = event.sessionID {
                    try db.execute(sql: """
                        INSERT INTO session_input_state (source, sessionID, lastPromptTokens, lastObservedAt)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(source, sessionID) DO UPDATE SET
                            lastPromptTokens = excluded.lastPromptTokens,
                            lastObservedAt = excluded.lastObservedAt
                        """, arguments: [event.source.rawValue, sessionID, event.promptTokens, event.observedAt])
                }
            }
        }
    }

    // Reset-aware positive delta of promptTokens within a (source, sessionID): a turn
    // whose prompt dropped below the last seen value (context compaction) or that opens
    // a session counts its full prompt as new; otherwise only the growth is new. Mirrors
    // the v9 backfill so live inserts and historical rows use identical math.
    private static func computeNewInputTokens(for event: UsageEvent, in db: Database) throws -> Int {
        guard let sessionID = event.sessionID else { return event.promptTokens }
        let previous: Int? = try Row.fetchOne(db, sql: """
            SELECT lastPromptTokens FROM session_input_state WHERE source = ? AND sessionID = ?
            """, arguments: [event.source.rawValue, sessionID])?["lastPromptTokens"]
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
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                guard let date = formatter.date(from: dayString) else { return nil }
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

            // Parse the period key as LOCAL midnight so the plotted Date lands inside
            // its bucket under Calendar.current. POSIX locale keeps parsing stable.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = Calendar.current.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")

            return rows.compactMap { row -> ChartDataPoint? in
                guard let periodKey: String = row["period"],
                      let date = formatter.date(from: periodKey) else { return nil }
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
        return try await dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT lastCursor FROM source_cursors WHERE source = ?", arguments: [source.rawValue])?["lastCursor"]
        }
    }

    func setCursor(for source: UsageEvent.Source, cursor: String) async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO source_cursors (source, lastCursor, lastScanAt) VALUES (?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET lastCursor = excluded.lastCursor, lastScanAt = excluded.lastScanAt
                """, arguments: [source.rawValue, cursor, Date()])
        }
    }
}
