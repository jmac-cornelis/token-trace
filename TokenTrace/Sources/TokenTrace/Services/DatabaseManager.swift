import Foundation
import GRDB

final class DatabaseManager {
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

        return migrator
    }

    // MARK: - Insert

    func insertEvents(_ events: [UsageEvent]) throws {
        try dbPool.write { db in
            for event in events {
                try event.insert(db)
            }
        }
    }

    // MARK: - Queries

    func todaySummary() throws -> (total: Int, prompt: Int, completion: Int, cached: Int, reasoning: Int, bySource: [UsageEvent.Source: Int]) {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source,
                       COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(completionTokens), 0) as completion,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cached,
                       COALESCE(SUM(reasoningTokens), 0) as reasoning
                FROM usage_events WHERE observedAt >= ?
                GROUP BY source
                """, arguments: [startOfDay])

            var totalAll = 0, promptAll = 0, completionAll = 0, cachedAll = 0, reasoningAll = 0
            var bySource: [UsageEvent.Source: Int] = [:]

            for row in rows {
                let source = UsageEvent.Source(rawValue: row["source"] as String) ?? .opencode
                let total: Int = row["total"]
                totalAll += total
                promptAll += row["prompt"]
                completionAll += row["completion"]
                cachedAll += row["cached"]
                reasoningAll += row["reasoning"]
                bySource[source] = total
            }

            return (totalAll, promptAll, completionAll, cachedAll, reasoningAll, bySource)
        }
    }

    func recentSessions(limit: Int = 10) throws -> [SessionSummary] {
        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionID, source, projectName, model, agent, sessionTitle,
                       COALESCE(SUM(totalTokens), 0) as totalTokens,
                       COALESCE(SUM(promptTokens), 0) as promptTokens,
                       COALESCE(SUM(completionTokens), 0) as completionTokens,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cachedTokens,
                       COALESCE(SUM(reasoningTokens), 0) as reasoningTokens,
                       COUNT(*) as eventCount,
                       MIN(observedAt) as firstSeen,
                       MAX(observedAt) as lastSeen
                FROM usage_events WHERE sessionID IS NOT NULL
                GROUP BY sessionID ORDER BY lastSeen DESC LIMIT ?
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
                    completionTokens: row["completionTokens"],
                    cachedTokens: row["cachedTokens"],
                    reasoningTokens: row["reasoningTokens"],
                    eventCount: row["eventCount"],
                    firstSeen: row["firstSeen"],
                    lastSeen: row["lastSeen"]
                )
            }
        }
    }

    // MARK: - Daily History

    func dailySummaries(days: Int = 14) throws -> [DailySummary] {
        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(observedAt) as day,
                       COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(completionTokens), 0) as completion,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cached,
                       COALESCE(SUM(reasoningTokens), 0) as reasoning,
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
                    completionTokens: row["completion"],
                    cachedTokens: row["cached"],
                    reasoningTokens: row["reasoning"],
                    sessionCount: row["sessionCount"]
                )
            }
        }
    }

    func sessionsForDate(_ date: Date) throws -> [SessionSummary] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionID, source, projectName, model, agent, sessionTitle,
                       COALESCE(SUM(totalTokens), 0) as totalTokens,
                       COALESCE(SUM(promptTokens), 0) as promptTokens,
                       COALESCE(SUM(completionTokens), 0) as completionTokens,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cachedTokens,
                       COALESCE(SUM(reasoningTokens), 0) as reasoningTokens,
                       COUNT(*) as eventCount,
                       MIN(observedAt) as firstSeen,
                       MAX(observedAt) as lastSeen
                FROM usage_events
                WHERE sessionID IS NOT NULL
                  AND observedAt >= ? AND observedAt < ?
                GROUP BY sessionID ORDER BY lastSeen DESC
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
                    completionTokens: row["completionTokens"],
                    cachedTokens: row["cachedTokens"],
                    reasoningTokens: row["reasoningTokens"],
                    eventCount: row["eventCount"],
                    firstSeen: row["firstSeen"],
                    lastSeen: row["lastSeen"]
                )
            }
        }
    }

    // MARK: - Chart Data

    func chartData(range: ChartRange) throws -> [ChartDataPoint] {
        return try dbPool.read { db in
            let whereClause: String
            let groupFormat: String
            let labelFormat: String

            switch range {
            case .week:
                whereClause = "WHERE observedAt >= date('now', '-7 days')"
                groupFormat = "date(observedAt)"
                labelFormat = "%m/%d"
            case .month:
                whereClause = "WHERE observedAt >= date('now', '-30 days')"
                groupFormat = "date(observedAt)"
                labelFormat = "%m/%d"
            case .year:
                whereClause = "WHERE observedAt >= date('now', '-365 days')"
                groupFormat = "strftime('%Y-%W', observedAt)"
                labelFormat = "%m/%d"
            case .total:
                whereClause = ""
                groupFormat = "strftime('%Y-%m', observedAt)"
                labelFormat = "%Y-%m"
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT \(groupFormat) as period,
                       MIN(observedAt) as periodDate,
                       COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(completionTokens), 0) as completion
                FROM usage_events
                \(whereClause)
                GROUP BY period
                ORDER BY period ASC
                """)

            let formatter = DateFormatter()
            formatter.dateFormat = labelFormat

            return rows.compactMap { row -> ChartDataPoint? in
                guard let date: Date = row["periodDate"] else { return nil }
                return ChartDataPoint(
                    date: date,
                    totalTokens: row["total"],
                    promptTokens: row["prompt"],
                    completionTokens: row["completion"],
                    label: formatter.string(from: date)
                )
            }
        }
    }

    func rangeSummary(range: ChartRange) throws -> (total: Int, prompt: Int, completion: Int, cached: Int, reasoning: Int) {
        return try dbPool.read { db in
            let whereClause: String
            if let days = range.days {
                whereClause = "WHERE observedAt >= date('now', '-\(days) days')"
            } else {
                whereClause = ""
            }

            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(totalTokens), 0) as total,
                       COALESCE(SUM(promptTokens), 0) as prompt,
                       COALESCE(SUM(completionTokens), 0) as completion,
                       COALESCE(SUM(cachedReadTokens) + SUM(cachedWriteTokens), 0) as cached,
                       COALESCE(SUM(reasoningTokens), 0) as reasoning
                FROM usage_events
                \(whereClause)
                """)

            guard let row = row else { return (0, 0, 0, 0, 0) }
            return (row["total"], row["prompt"], row["completion"], row["cached"], row["reasoning"])
        }
    }

    // MARK: - Cursor Management

    func getCursor(for source: UsageEvent.Source) throws -> String? {
        return try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT lastCursor FROM source_cursors WHERE source = ?", arguments: [source.rawValue])?["lastCursor"]
        }
    }

    func setCursor(for source: UsageEvent.Source, cursor: String) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO source_cursors (source, lastCursor, lastScanAt) VALUES (?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET lastCursor = excluded.lastCursor, lastScanAt = excluded.lastScanAt
                """, arguments: [source.rawValue, cursor, Date()])
        }
    }
}
