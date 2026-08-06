import Testing
import Foundation
import GRDB
@testable import TokenTrace

@Suite("OpenCodeReader")
struct OpenCodeReaderTests {

    private func makeReader() throws -> (OpenCodeReader, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("opencode.db").path
        try createMockOpenCodeDB(at: dbPath)
        return (OpenCodeReader(dbPath: dbPath), tempDir)
    }

    @Test func fetchEventsReturnsAssistantMessages() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, cursor) = reader.fetchEvents(since: nil)
        #expect(events.count == 2)
        #expect(cursor != nil)

        let first = events[0]
        #expect(first.source == .opencode)
        #expect(first.promptTokens == 1000)
        #expect(first.completionTokens == 500)
        #expect(first.totalTokens == 1500)
        #expect(first.model == "developer-opus")
        #expect(first.provider == "cornelis")
        #expect(first.lastPrompt == "Latest user prompt")
    }

    @Test func cursorFiltersOldMessages() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (allEvents, cursor) = reader.fetchEvents(since: nil)
        #expect(allEvents.count == 2)

        let (newEvents, _) = reader.fetchEvents(since: cursor)
        #expect(newEvents.isEmpty)
    }

    @Test func fetchEventsSkipsZeroTokenMessages() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        for event in events {
            #expect(event.totalTokens > 0)
        }
    }

    @Test func projectNameResolution() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        let withProject = events.first { $0.projectName == "test-project" }
        #expect(withProject != nil)
    }

    @Test func globalProjectFallsBackToSessionDirectory() throws {
        let (reader, tempDir) = try makeGlobalProjectReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 1)
        #expect(events[0].projectName == "scratch")
        #expect(events[0].repoPath == "/Users/test/scratch")
    }

    @Test func resolveRepoPathRejectsRootWorktree() {
        #expect(OpenCodeReader.resolveRepoPath(worktree: "/", sessionDirectory: "/Users/test/scratch") == "/Users/test/scratch")
        #expect(OpenCodeReader.resolveRepoPath(worktree: "", sessionDirectory: "/Users/test/scratch") == "/Users/test/scratch")
        #expect(OpenCodeReader.resolveRepoPath(worktree: nil, sessionDirectory: "/Users/test/scratch") == "/Users/test/scratch")
        #expect(OpenCodeReader.resolveRepoPath(worktree: "/Users/test/repo", sessionDirectory: "/Users/test/scratch") == "/Users/test/repo")
        #expect(OpenCodeReader.resolveRepoPath(worktree: "/", sessionDirectory: "/") == nil)
    }

    @Test func resolveProjectNameNeverReturnsRoot() {
        #expect(OpenCodeReader.resolveProjectName(projectName: "named", repoPath: "/Users/test/repo") == "named")
        #expect(OpenCodeReader.resolveProjectName(projectName: "", repoPath: "/Users/test/repo") == "repo")
        #expect(OpenCodeReader.resolveProjectName(projectName: nil, repoPath: "/") == nil)
        #expect(OpenCodeReader.resolveProjectName(projectName: nil, repoPath: nil) == nil)
    }

    @Test func unpricedTurnsGetEstimatedCost() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        let opus = try #require(events.first { $0.model == "developer-opus" })
        #expect(opus.estimatedCostUSD > 0)
    }

    @Test func reportedCostWins() {
        let resolved = OpenCodeReader.resolveCost(
            reportedCost: 1.25,
            model: "developer-opus",
            observedAt: Date(),
            promptTokens: 1000,
            completionTokens: 500,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0
        )
        #expect(resolved == 1.25)
    }

    @Test func unpricedModelStaysZero() {
        let resolved = OpenCodeReader.resolveCost(
            reportedCost: 0,
            model: "assistant",
            observedAt: Date(),
            promptTokens: 100_000,
            completionTokens: 5_000,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0
        )
        #expect(resolved == 0)
    }

    @Test func negativeReportedCostNeverSurvives() {
        // OpenCode stores a negative $.cost on 42 rows. An unpriced model takes the
        // guard's else-path, which must not pass the negative value through.
        let resolved = OpenCodeReader.resolveCost(
            reportedCost: -0.115665,
            model: "assistant",
            observedAt: Date(),
            promptTokens: 1000,
            completionTokens: 500,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0
        )
        #expect(resolved == 0)
    }

    @Test func negativeOutputTokensAreClamped() throws {
        let (reader, tempDir) = try makeNegativeOutputReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        let event = try #require(events.first)
        #expect(event.completionTokens == 0)
        #expect(event.promptTokens == 276_001)
        // `total` is preserved as reported, never recomputed from the components.
        #expect(event.totalTokens == 230_638)
        #expect(event.estimatedCostUSD > 0)
    }

    @Test func preMayPricingUsesHistoricalRates() {
        // developer-gpt output went from $15/M to $30/M on 2026-05-01; a March turn
        // must be priced at the older rate, not at today's configured rate.
        let march = Date(timeIntervalSince1970: 1_772_000_000)  // 2026-02-25
        let june = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-05-29

        let old = OpenCodeReader.resolveCost(
            reportedCost: 0, model: "developer-gpt", observedAt: march,
            promptTokens: 0, completionTokens: 1_000_000,
            cachedReadTokens: 0, cachedWriteTokens: 0, reasoningTokens: 0
        )
        let new = OpenCodeReader.resolveCost(
            reportedCost: 0, model: "developer-gpt", observedAt: june,
            promptTokens: 0, completionTokens: 1_000_000,
            cachedReadTokens: 0, cachedWriteTokens: 0, reasoningTokens: 0
        )
        #expect(old < new)
    }

    @Test func sessionTitlePopulated() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        let withTitle = events.first { $0.sessionTitle == "Test session" }
        #expect(withTitle != nil)
    }

    @Test func healthCheckWithValidDB() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let health = reader.healthCheck()
        #expect(health.isHealthy)
        #expect(health.eventCount == 2)
        #expect(health.lastEventTime != nil)
    }

    @Test func healthCheckWithMissingDB() {
        let reader = OpenCodeReader(dbPath: "/nonexistent/opencode.db")
        let health = reader.healthCheck()
        #expect(!health.isHealthy)
    }

    @Test func connectThrowsForMissingDB() {
        let reader = OpenCodeReader(dbPath: "/nonexistent/opencode.db")
        #expect(throws: (any Error).self) { try reader.connect() }
    }

    private func makeGlobalProjectReader() throws -> (OpenCodeReader, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("opencode.db").path
        try createMockOpenCodeDB(at: dbPath, globalProject: true)
        return (OpenCodeReader(dbPath: dbPath), tempDir)
    }

    private func makeNegativeOutputReader() throws -> (OpenCodeReader, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("opencode.db").path
        try createMockOpenCodeDB(at: dbPath, negativeOutput: true)
        return (OpenCodeReader(dbPath: dbPath), tempDir)
    }

    private func createMockOpenCodeDB(at path: String, globalProject: Bool = false, negativeOutput: Bool = false) throws {
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT, name TEXT,
                    icon_url TEXT, icon_color TEXT, time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL, time_initialized INTEGER,
                    sandboxes TEXT NOT NULL DEFAULT '', commands TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY, project_id TEXT REFERENCES project(id),
                    parent_id TEXT, slug TEXT, directory TEXT, title TEXT, version TEXT,
                    share_url TEXT, summary_additions TEXT, summary_deletions TEXT,
                    summary_files TEXT, summary_diffs TEXT, revert TEXT, permission TEXT,
                    time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
                    time_compacting INTEGER, time_archived INTEGER, workspace_id TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE message (
                    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES session(id),
                    time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE part (
                    id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES message(id),
                    data TEXT NOT NULL
                )
                """)

            let now = Int64(Date().timeIntervalSince1970 * 1000)

            if negativeOutput {
                // Verbatim shape of the worst real developer-gpt row: input dominates a
                // negative output, and `total` agrees with the corrupt component sum.
                try db.execute(sql: "INSERT INTO project VALUES ('global', '/', NULL, NULL, NULL, NULL, ?, ?, NULL, '', NULL)", arguments: [now, now])
                try db.execute(sql: "INSERT INTO session VALUES ('ses_n', 'global', NULL, NULL, '/Users/test/scratch', 'Negative session', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, NULL, NULL, NULL)", arguments: [now, now])
                let negativeMsg = """
                {"role":"assistant","modelID":"developer-gpt","providerID":"cornelis","tokens":{"total":230638,"input":276001,"output":-45363,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0,"time":{"created":\(now)}}
                """
                try db.execute(sql: "INSERT INTO message VALUES ('msg_n', 'ses_n', ?, ?, ?)", arguments: [now, now, negativeMsg])
                return
            }

            if globalProject {
                // Mirrors OpenCode's synthetic catch-all project row: all 16 real rows
                // carry a NULL name alongside worktree '/'.
                try db.execute(sql: "INSERT INTO project VALUES ('global', '/', NULL, NULL, NULL, NULL, ?, ?, NULL, '', NULL)", arguments: [now, now])
                try db.execute(sql: "INSERT INTO session VALUES ('ses_g', 'global', NULL, NULL, '/Users/test/scratch', 'Global session', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, NULL, NULL, NULL)", arguments: [now, now])
                let globalMsg = """
                {"role":"assistant","modelID":"developer-opus","providerID":"cornelis","tokens":{"total":1500,"input":1000,"output":500,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0,"time":{"created":\(now)}}
                """
                try db.execute(sql: "INSERT INTO message VALUES ('msg_g', 'ses_g', ?, ?, ?)", arguments: [now, now, globalMsg])
                return
            }

            try db.execute(sql: "INSERT INTO project VALUES ('proj_1', '/Users/test/code/test-project', NULL, 'test-project', NULL, NULL, ?, ?, NULL, '', NULL)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO session VALUES ('ses_1', 'proj_1', NULL, NULL, '/Users/test/code/test-project', 'Test session', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, NULL, NULL, NULL)", arguments: [now, now])

            let msg1Data = """
            {"role":"assistant","modelID":"developer-opus","providerID":"cornelis","agent":"Sisyphus","tokens":{"total":1500,"input":1000,"output":500,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0,"time":{"created":\(now)}}
            """
            try db.execute(sql: "INSERT INTO message VALUES ('msg_1', 'ses_1', ?, ?, ?)", arguments: [now, now, msg1Data])

            let msg2Data = """
            {"role":"assistant","modelID":"developer-sonnet","providerID":"cornelis","agent":"explore","tokens":{"total":800,"input":300,"output":500,"reasoning":0,"cache":{"read":100,"write":50}},"cost":0,"time":{"created":\(now + 1000)}}
            """
            try db.execute(sql: "INSERT INTO message VALUES ('msg_2', 'ses_1', ?, ?, ?)", arguments: [now + 1000, now + 1000, msg2Data])

            let msg3Data = """
            {"role":"user","time":{"created":\(now + 500)}}
            """
            try db.execute(sql: "INSERT INTO message VALUES ('msg_3', 'ses_1', ?, ?, ?)", arguments: [now + 500, now + 500, msg3Data])
            let msg3PartData = """
            {"text":"Latest user prompt"}
            """
            try db.execute(sql: "INSERT INTO part VALUES ('part_1', 'msg_3', ?)", arguments: [msg3PartData])

            let msg4Data = """
            {"role":"assistant","modelID":"developer-opus","providerID":"cornelis","agent":"Sisyphus","tokens":{"total":0,"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0}
            """
            try db.execute(sql: "INSERT INTO message VALUES ('msg_4', 'ses_1', ?, ?, ?)", arguments: [now + 2000, now + 2000, msg4Data])
        }
    }
}
