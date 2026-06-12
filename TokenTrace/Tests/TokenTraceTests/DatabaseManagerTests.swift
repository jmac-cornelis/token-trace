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

    @Test func insertAndTodaySummary() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150),
            makeEvent(source: .opencode, prompt: 200, completion: 100, total: 300),
            makeEvent(source: .openclaw, prompt: 50, completion: 25, total: 75),
        ]
        try await db.insertEvents(events)

        let summary = try await db.todaySummary()
        #expect(summary.total == 525)
        #expect(summary.prompt == 350)
        #expect(summary.completion == 175)
        #expect(summary.bySource[.opencode] == 450)
        #expect(summary.bySource[.openclaw] == 75)
    }

    @Test func todaySummaryExcludesYesterday() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150),
            makeEvent(source: .opencode, prompt: 999, completion: 999, total: 1998, date: yesterday),
        ]
        try await db.insertEvents(events)

        let summary = try await db.todaySummary()
        #expect(summary.total == 150)
    }

    @Test func emptyDatabaseReturnsZeros() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let summary = try await db.todaySummary()
        #expect(summary.total == 0)
        #expect(summary.prompt == 0)
        #expect(summary.completion == 0)
    }

    @Test func recentSessionsGroupsBySessionID() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150, sessionID: "ses_1", project: "proj-a"),
            makeEvent(source: .opencode, prompt: 200, completion: 100, total: 300, sessionID: "ses_1", project: "proj-a"),
            makeEvent(source: .openclaw, prompt: 50, completion: 25, total: 75, sessionID: "task_2", project: "proj-b"),
        ]
        try await db.insertEvents(events)

        let sessions = try await db.recentSessions(limit: 10)
        #expect(sessions.count == 2)

        let ses1 = sessions.first { $0.id == "ses_1" }
        #expect(ses1 != nil)
        #expect(ses1?.totalTokens == 450)
        #expect(ses1?.eventCount == 2)
        #expect(ses1?.source == .opencode)
    }

    @Test func recentSessionsRespectsLimit() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<20 {
            try await db.insertEvents([makeEvent(source: .opencode, total: 100, sessionID: "ses_\(i)")])
        }
        let sessions = try await db.recentSessions(limit: 5)
        #expect(sessions.count == 5)
    }

    @Test func dailySummariesGroupsByDate() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let events = [
            makeEvent(source: .opencode, total: 100, date: today),
            makeEvent(source: .opencode, total: 200, date: today),
            makeEvent(source: .openclaw, total: 300, date: yesterday),
        ]
        try await db.insertEvents(events)

        let summaries = try await db.dailySummaries(days: 7)
        #expect(summaries.count == 2)

        let todaySummary = summaries.first { $0.isToday }
        #expect(todaySummary != nil)
        #expect(todaySummary?.totalTokens == 300)
    }

    @Test func sessionsForDateFiltersCorrectly() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let events = [
            makeEvent(source: .opencode, total: 100, sessionID: "ses_today", date: today),
            makeEvent(source: .opencode, total: 200, sessionID: "ses_yesterday", date: yesterday),
        ]
        try await db.insertEvents(events)

        let todaySessions = try await db.sessionsForDate(today)
        #expect(todaySessions.count == 1)
        #expect(todaySessions.first?.id == "ses_today")

        let yesterdaySessions = try await db.sessionsForDate(yesterday)
        #expect(yesterdaySessions.count == 1)
        #expect(yesterdaySessions.first?.id == "ses_yesterday")
    }

    @Test func chartDataWeekRange() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let today = Date()
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: today)!
        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150, date: today),
            makeEvent(source: .openclaw, prompt: 200, completion: 100, total: 300, date: threeDaysAgo),
        ]
        try await db.insertEvents(events)

        let data = try await db.chartData(range: .week)
        #expect(data.count >= 2)

        let totalAcrossPoints = data.reduce(0) { $0 + $1.totalTokens }
        #expect(totalAcrossPoints == 450)
    }

    @Test func chartDataTotalRange() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await db.insertEvents([makeEvent(source: .opencode, total: 500)])
        let data = try await db.chartData(range: .total)
        #expect(!data.isEmpty)
    }

    @Test func rangeSummary() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = [
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150),
            makeEvent(source: .openclaw, prompt: 200, completion: 100, total: 300),
        ]
        try await db.insertEvents(events)

        let summary = try await db.rangeSummary(range: .week)
        #expect(summary.total == 450)
        #expect(summary.prompt == 300)
        #expect(summary.completion == 150)
    }

    @Test func rangeSummaryTotalIncludesAllData() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longAgo = Calendar.current.date(byAdding: .year, value: -2, to: Date())!
        try await db.insertEvents([
            makeEvent(source: .opencode, total: 100),
            makeEvent(source: .opencode, total: 200, date: longAgo),
        ])

        let weekSummary = try await db.rangeSummary(range: .week)
        #expect(weekSummary.total == 100)

        let totalSummary = try await db.rangeSummary(range: .total)
        #expect(totalSummary.total == 300)
    }

    @Test func cursorRoundTrip() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(try await db.getCursor(for: .opencode) == nil)

        try await db.setCursor(for: .opencode, cursor: "12345")
        #expect(try await db.getCursor(for: .opencode) == "12345")

        try await db.setCursor(for: .opencode, cursor: "67890")
        #expect(try await db.getCursor(for: .opencode) == "67890")
    }

    @Test func cursorsArePerSource() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await db.setCursor(for: .opencode, cursor: "aaa")
        try await db.setCursor(for: .openclaw, cursor: "bbb")
        try await db.setCursor(for: .codex, cursor: "ccc")

        #expect(try await db.getCursor(for: .opencode) == "aaa")
        #expect(try await db.getCursor(for: .openclaw) == "bbb")
        #expect(try await db.getCursor(for: .codex) == "ccc")
    }

    @Test func codexSourceInSummary() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await db.insertEvents([makeEvent(source: .codex, prompt: 0, completion: 500, total: 500)])

        let summary = try await db.todaySummary()
        #expect(summary.bySource[.codex] == 500)
        #expect(summary.total == 500)
    }

    @Test func newInputTokensStripsResentContextWithinSession() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let base = Date()
        func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

        // OpenCode reports promptTokens as the full re-sent context each turn, so it grows
        // monotonically; a drop signals a context reset (compaction/sub-conversation), where
        // the whole prompt is genuinely new again.
        try await db.insertEvents([
            makeEvent(source: .opencode, prompt: 1_000, total: 1_000, sessionID: "ses_delta", date: at(0)),
            makeEvent(source: .opencode, prompt: 1_500, total: 1_500, sessionID: "ses_delta", date: at(1)),
            makeEvent(source: .opencode, prompt: 2_200, total: 2_200, sessionID: "ses_delta", date: at(2)),
            makeEvent(source: .opencode, prompt: 800, total: 800, sessionID: "ses_delta", date: at(3)),
        ])

        let deltas = try await db.dbPool.read { db in
            try Int.fetchAll(db, sql: """
                SELECT newInputTokens FROM usage_events
                WHERE sessionID = 'ses_delta' ORDER BY observedAt, id
                """)
        }
        #expect(deltas == [1_000, 500, 700, 800])
    }

    @Test func newInputTokensEqualsPromptForSessionlessRows() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await db.insertEvents([
            makeEvent(source: .continue, prompt: 1_200, total: 1_200, sessionID: nil),
            makeEvent(source: .continue, prompt: 900, total: 900, sessionID: nil),
        ])

        let deltas = try await db.dbPool.read { db in
            try Int.fetchAll(db, sql: """
                SELECT newInputTokens FROM usage_events WHERE source = 'continue' ORDER BY id
                """)
        }
        #expect(deltas.sorted() == [900, 1_200])
    }

    @Test func newInputTokensIsolatesSessions() async throws {
        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let base = Date()
        try await db.insertEvents([
            makeEvent(source: .opencode, prompt: 1_000, total: 1_000, sessionID: "ses_a", date: base.addingTimeInterval(0)),
            makeEvent(source: .opencode, prompt: 5_000, total: 5_000, sessionID: "ses_b", date: base.addingTimeInterval(1)),
            makeEvent(source: .opencode, prompt: 1_300, total: 1_300, sessionID: "ses_a", date: base.addingTimeInterval(2)),
        ])

        let aDeltas = try await db.dbPool.read { db in
            try Int.fetchAll(db, sql: "SELECT newInputTokens FROM usage_events WHERE sessionID = 'ses_a' ORDER BY observedAt, id")
        }
        let bDeltas = try await db.dbPool.read { db in
            try Int.fetchAll(db, sql: "SELECT newInputTokens FROM usage_events WHERE sessionID = 'ses_b' ORDER BY observedAt, id")
        }
        #expect(aDeltas == [1_000, 300])
        #expect(bDeltas == [5_000])
    }

    @Test func legacyRooMigrationClearsRowsAndCursor() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db").path
        try createPreMigrationDatabase(at: dbPath)

        let db = DatabaseManager(path: dbPath)
        try db.setup()

        let summary = try await db.todaySummary()
        #expect(summary.bySource[.opencode] == 150)
        #expect(summary.total == 150)

        let rooRows = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events WHERE source = 'roo'") ?? 0
        }
        #expect(rooRows == 0)
    }

    @MainActor
    @Test func usageStoreRefreshLoadsTodaysTotals() async throws {
        let settings = SettingsManager.shared
        let previousMode = settings.dataSourceMode
        settings.dataSourceMode = .local
        defer { settings.dataSourceMode = previousMode }

        let (db, tempDir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await db.insertEvents([
            makeEvent(source: .openclaw, prompt: 48_442, completion: 24_724, total: 73_166, date: Date()),
            makeEvent(source: .opencode, prompt: 100, completion: 50, total: 150, date: Date()),
        ])

        let store = UsageStore(db: db)
        await store.refreshNow()

        #expect(store.openclawTokens == 73_166)
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
            // 'roo' is no longer a valid UsageEvent.Source, so seed legacy rows via raw SQL
            // to exercise the v7/v8 migration that purges them.
            for (sessionID, total) in [("roo-legacy", 75), ("roo-current", 125)] {
                try db.execute(
                    sql: """
                        INSERT INTO usage_events (id, observedAt, source, sessionID, totalTokens)
                        VALUES (?, ?, 'roo', ?, ?)
                        """,
                    arguments: [UUID().uuidString, Date(), sessionID, total]
                )
            }
            // Insert via raw SQL: the pre-migration schema (v1-v6) predates the v9
            // newInputTokens column, so UsageEvent.insert (which emits that column) would fail.
            try db.execute(
                sql: """
                    INSERT INTO usage_events (id, observedAt, source, sessionID, totalTokens)
                    VALUES (?, ?, 'opencode', ?, ?)
                    """,
                arguments: [UUID().uuidString, Date(), "opencode-1", 150]
            )
            try db.execute(
                sql: "INSERT INTO source_cursors (source, lastCursor, lastScanAt) VALUES (?, ?, ?)",
                arguments: ["roo", "{\"lastTimestamp\":123}", Date()]
            )
        }
    }
}
