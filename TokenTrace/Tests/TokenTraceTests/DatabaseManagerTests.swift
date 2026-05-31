import Testing
import Foundation
import GRDB
@testable import TokenTrace

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    private func makeDB() throws -> (DatabaseManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db").path
        let db = DatabaseManager(path: dbPath)
        try db.setup()
        return (db, tempDir)
    }

    @Test func insertAndTodaySummary() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150),
            makeEvent(source: .opencode, prompt: 200, completion: 100, total: 300),
            makeEvent(source: .roo, prompt: 50, completion: 25, total: 75),
        ]
        try db.insertEvents(events)

        let summary = try db.todaySummary()
        #expect(summary.total == 525)
        #expect(summary.prompt == 350)
        #expect(summary.completion == 175)
        #expect(summary.bySource[.opencode] == 450)
        #expect(summary.bySource[.roo] == 75)
    }

    @Test func todaySummaryExcludesYesterday() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150),
            makeEvent(source: .opencode, prompt: 999, completion: 999, total: 1998, date: yesterday),
        ]
        try db.insertEvents(events)

        let summary = try db.todaySummary()
        #expect(summary.total == 150)
    }

    @Test func emptyDatabaseReturnsZeros() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let summary = try db.todaySummary()
        #expect(summary.total == 0)
        #expect(summary.prompt == 0)
        #expect(summary.completion == 0)
    }

    @Test func recentSessionsGroupsBySessionID() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150, sessionID: "ses_1", project: "proj-a"),
            makeEvent(source: .opencode, prompt: 200, completion: 100, total: 300, sessionID: "ses_1", project: "proj-a"),
            makeEvent(source: .roo, prompt: 50, completion: 25, total: 75, sessionID: "task_2", project: "proj-b"),
        ]
        try db.insertEvents(events)

        let sessions = try db.recentSessions(limit: 10)
        #expect(sessions.count == 2)

        let ses1 = sessions.first { $0.id == "ses_1" }
        #expect(ses1 != nil)
        #expect(ses1?.totalTokens == 450)
        #expect(ses1?.eventCount == 2)
        #expect(ses1?.source == .opencode)
    }

    @Test func recentSessionsRespectsLimit() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<20 {
            try db.insertEvents([makeEvent(source: .opencode, total: 100, sessionID: "ses_\(i)")])
        }
        let sessions = try db.recentSessions(limit: 5)
        #expect(sessions.count == 5)
    }

    @Test func dailySummariesGroupsByDate() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let events = [
            makeEvent(source: .opencode, total: 100, date: today),
            makeEvent(source: .opencode, total: 200, date: today),
            makeEvent(source: .roo, total: 300, date: yesterday),
        ]
        try db.insertEvents(events)

        let summaries = try db.dailySummaries(days: 7)
        #expect(summaries.count == 2)

        let todaySummary = summaries.first { $0.isToday }
        #expect(todaySummary != nil)
        #expect(todaySummary?.totalTokens == 300)
    }

    @Test func sessionsForDateFiltersCorrectly() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let events = [
            makeEvent(source: .opencode, total: 100, sessionID: "ses_today", date: today),
            makeEvent(source: .opencode, total: 200, sessionID: "ses_yesterday", date: yesterday),
        ]
        try db.insertEvents(events)

        let todaySessions = try db.sessionsForDate(today)
        #expect(todaySessions.count == 1)
        #expect(todaySessions.first?.id == "ses_today")

        let yesterdaySessions = try db.sessionsForDate(yesterday)
        #expect(yesterdaySessions.count == 1)
        #expect(yesterdaySessions.first?.id == "ses_yesterday")
    }

    @Test func chartDataWeekRange() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let today = Date()
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: today)!
        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150, date: today),
            makeEvent(source: .roo, prompt: 200, completion: 100, total: 300, date: threeDaysAgo),
        ]
        try db.insertEvents(events)

        let data = try db.chartData(range: .week)
        #expect(data.count >= 2)

        let totalAcrossPoints = data.reduce(0) { $0 + $1.totalTokens }
        #expect(totalAcrossPoints == 450)
    }

    @Test func chartDataTotalRange() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try db.insertEvents([makeEvent(source: .opencode, total: 500)])
        let data = try db.chartData(range: .total)
        #expect(!data.isEmpty)
    }

    @Test func rangeSummary() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150),
            makeEvent(source: .roo, prompt: 200, completion: 100, total: 300),
        ]
        try db.insertEvents(events)

        let summary = try db.rangeSummary(range: .week)
        #expect(summary.total == 450)
        #expect(summary.prompt == 300)
        #expect(summary.completion == 150)
    }

    @Test func rangeSummaryTotalIncludesAllData() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longAgo = Calendar.current.date(byAdding: .year, value: -2, to: Date())!
        try db.insertEvents([
            makeEvent(source: .opencode, total: 100),
            makeEvent(source: .opencode, total: 200, date: longAgo),
        ])

        let weekSummary = try db.rangeSummary(range: .week)
        #expect(weekSummary.total == 100)

        let totalSummary = try db.rangeSummary(range: .total)
        #expect(totalSummary.total == 300)
    }

    @Test func cursorRoundTrip() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(try db.getCursor(for: .opencode) == nil)

        try db.setCursor(for: .opencode, cursor: "12345")
        #expect(try db.getCursor(for: .opencode) == "12345")

        try db.setCursor(for: .opencode, cursor: "67890")
        #expect(try db.getCursor(for: .opencode) == "67890")
    }

    @Test func cursorsArePerSource() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try db.setCursor(for: .opencode, cursor: "aaa")
        try db.setCursor(for: .roo, cursor: "bbb")
        try db.setCursor(for: .codex, cursor: "ccc")

        #expect(try db.getCursor(for: .opencode) == "aaa")
        #expect(try db.getCursor(for: .roo) == "bbb")
        #expect(try db.getCursor(for: .codex) == "ccc")
    }

    @Test func codexSourceInSummary() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try db.insertEvents([makeEvent(source: .codex, prompt: 0, completion: 500, total: 500)])

        let summary = try db.todaySummary()
        #expect(summary.bySource[.codex] == 500)
        #expect(summary.total == 500)
    }

    @Test func rooMigrationClearsLegacyRowsAndCursor() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db").path
        try createPreMigrationDatabase(at: dbPath)

        let db = DatabaseManager(path: dbPath)
        try db.setup()

        let summary = try db.todaySummary()
        #expect(summary.bySource[.roo] == nil)
        #expect(summary.bySource[.opencode] == 150)
        #expect(summary.total == 150)
        #expect(try db.getCursor(for: .roo) == nil)
    }

    @Test func rooSnapshotStoreRoundTripsSnapshots() throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let firstSeenAt = Date(timeIntervalSince1970: 1_700_000_000)
        try db.saveSnapshots([
            RooTaskSnapshot(
                taskID: "task-1",
                tokensIn: 120,
                tokensOut: 80,
                cacheWrites: 12,
                cacheReads: 20,
                totalCost: 1.75,
                lastTimestamp: 1_700_000_500,
                status: "active",
                firstSeenAt: firstSeenAt
            )
        ])

        let saved = try #require(db.snapshots(for: ["task-1"])["task-1"])
        #expect(saved.tokensIn == 120)
        #expect(saved.tokensOut == 80)
        #expect(saved.cacheWrites == 12)
        #expect(saved.cacheReads == 20)
        #expect(saved.totalCost == 1.75)
        #expect(saved.lastTimestamp == 1_700_000_500)
        #expect(saved.status == "active")
        #expect(saved.firstSeenAt == firstSeenAt)

        try db.saveSnapshots([
            RooTaskSnapshot(
                taskID: "task-1",
                tokensIn: 140,
                tokensOut: 95,
                cacheWrites: 14,
                cacheReads: 25,
                totalCost: 2.0,
                lastTimestamp: 1_700_000_900,
                status: "complete",
                firstSeenAt: firstSeenAt
            )
        ])

        let updated = try #require(db.snapshots(for: ["task-1"])["task-1"])
        #expect(updated.tokensIn == 140)
        #expect(updated.tokensOut == 95)
        #expect(updated.cacheWrites == 14)
        #expect(updated.cacheReads == 25)
        #expect(updated.totalCost == 2.0)
        #expect(updated.lastTimestamp == 1_700_000_900)
        #expect(updated.status == "complete")
        #expect(updated.firstSeenAt == firstSeenAt)
    }

    @MainActor
    @Test func usageStoreRefreshLoadsTodaysRooTotals() throws {
        let settings = SettingsManager.shared
        let previousMode = settings.dataSourceMode
        settings.dataSourceMode = .local
        defer { settings.dataSourceMode = previousMode }

        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try db.insertEvents([
            makeEvent(source: .roo, prompt: 48_442, completion: 24_724, total: 73_166, date: Date()),
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150, date: Date()),
        ])

        let store = UsageStore(db: db)
        store.refresh()

        #expect(store.rooCodeTokens == 73_166)
        #expect(store.todayTotalTokens == 73_316)
        #expect(store.openCodeTokens == 150)
    }

    private func makeEvent(
        source: UsageEvent.Source = .opencode,
        prompt: Int = 0,
        completion: Int = 0,
        cached: Int = 0,
        reasoning: Int = 0,
        total: Int = 0,
        sessionID: String? = nil,
        sessionTitle: String? = nil,
        project: String? = nil,
        model: String? = nil,
        date: Date = Date()
    ) -> UsageEvent {
        UsageEvent(
            id: UUID().uuidString,
            observedAt: date,
            source: source,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            requestID: UUID().uuidString,
            projectName: project,
            repoPath: nil,
            provider: nil,
            model: model,
            agent: nil,
            promptTokens: prompt,
            completionTokens: completion,
            cachedReadTokens: cached,
            cachedWriteTokens: 0,
            reasoningTokens: reasoning,
            totalTokens: total,
            estimatedCostUSD: 0
        )
    }

    private func createPreMigrationDatabase(at path: String) throws {
        let dbQueue = try DatabaseQueue(path: path)

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
        migrator.registerMigration("v4-fix-codex-timestamps") { _ in }
        migrator.registerMigration("v5-codex-per-request") { db in
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'codex'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'codex'")
        }
        migrator.registerMigration("v6-codex-live-sessions") { db in
            try db.execute(sql: "DELETE FROM usage_events WHERE source = 'codex'")
            try db.execute(sql: "DELETE FROM source_cursors WHERE source = 'codex'")
        }

        try migrator.migrate(dbQueue)

        try dbQueue.write { db in
            try makeEvent(source: .roo, total: 75, sessionID: "roo-legacy", date: Date()).insert(db)
            try makeEvent(source: .roo, total: 125, sessionID: "roo-current", date: Date()).insert(db)
            try makeEvent(source: .opencode, total: 150, sessionID: "opencode-1", date: Date()).insert(db)
            try db.execute(
                sql: "INSERT INTO source_cursors (source, lastCursor, lastScanAt) VALUES (?, ?, ?)",
                arguments: [UsageEvent.Source.roo.rawValue, "{\"lastTimestamp\":123}", Date()]
            )
        }
    }
}
