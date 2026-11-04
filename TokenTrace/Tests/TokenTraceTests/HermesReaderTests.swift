import Testing
import Foundation
import GRDB
@testable import TokenTrace

@Suite("HermesReader")
struct HermesReaderTests {

    private func makeHermesRoot() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let avImplDir = tempDir.appendingPathComponent("profiles/av-implementer")
        let loopArchDir = tempDir.appendingPathComponent("profiles/hermes-loop-architect")
        try FileManager.default.createDirectory(at: avImplDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loopArchDir, withIntermediateDirectories: true)

        try createMockHermesDB(
            at: avImplDir.appendingPathComponent("state.db").path,
            sessionId: "local-av-1",
            profile: "av-implementer",
            model: "developer-sonnet",
            title: "Implement stage task",
            cwd: "/Users/test/worktrees/project-alpha",
            inputTokens: 40,
            outputTokens: 9_680,
            cacheReadTokens: 1_284_794,
            cacheWriteTokens: 277_840,
            timestamp: 1_793_759_466.0
        )

        try createMockHermesDB(
            at: loopArchDir.appendingPathComponent("state.db").path,
            sessionId: "local-loop-1",
            profile: "hermes-loop-architect",
            model: "developer-opus",
            title: "Architect stage task",
            cwd: "/Users/test/worktrees/project-beta",
            inputTokens: 120,
            outputTokens: 4_500,
            cacheReadTokens: 500_000,
            cacheWriteTokens: 80_000,
            timestamp: 1_793_800_000.0
        )

        return tempDir
    }

    @Test func discoversAllProfileStateDBs() throws {
        let tempDir = try makeHermesRoot()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = HermesReader(hermesRootPaths: [tempDir.path])
        let discovered = reader.discoverDatabasePaths()
        #expect(discovered.count == 2)
    }

    @Test func fetchesUsageAcrossProfilesAndComputesCost() throws {
        let tempDir = try makeHermesRoot()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = HermesReader(hermesRootPaths: [tempDir.path])
        try reader.connect()

        let (events, cursor) = reader.fetchEvents(since: nil)
        #expect(events.count == 2)
        #expect(cursor != nil)

        let av = try #require(events.first { $0.agent == "av-implementer" })
        #expect(av.source == .hermes)
        #expect(av.promptTokens == 40)
        #expect(av.completionTokens == 9_680)
        #expect(av.cachedReadTokens == 1_284_794)
        #expect(av.cachedWriteTokens == 277_840)
        #expect(av.totalTokens == 40 + 9_680 + 1_284_794 + 277_840)
        #expect(av.projectName == "project-alpha")
        #expect(av.estimatedCostUSD > 0)

        // Incremental cursor returns no duplicates when unchanged.
        let (nextEvents, _) = reader.fetchEvents(since: cursor)
        #expect(nextEvents.isEmpty)
    }

    @Test func healthCheckAggregatesAcrossProfiles() throws {
        let tempDir = try makeHermesRoot()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = HermesReader(hermesRootPaths: [tempDir.path])
        try reader.connect()

        let health = reader.healthCheck()
        #expect(health.isHealthy)
        #expect(health.eventCount == 2)
        #expect(health.lastEventTime != nil)
    }

    private func createMockHermesDB(
        at path: String,
        sessionId: String,
        profile: String,
        model: String,
        title: String,
        cwd: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        timestamp: Double
    ) throws {
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    model TEXT,
                    started_at REAL NOT NULL,
                    last_activity_at REAL,
                    input_tokens INTEGER DEFAULT 0,
                    output_tokens INTEGER DEFAULT 0,
                    cache_read_tokens INTEGER DEFAULT 0,
                    cache_write_tokens INTEGER DEFAULT 0,
                    reasoning_tokens INTEGER DEFAULT 0,
                    cwd TEXT,
                    git_repo_root TEXT,
                    billing_provider TEXT,
                    estimated_cost_usd REAL,
                    actual_cost_usd REAL,
                    title TEXT,
                    profile_name TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE session_model_usage (
                    session_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    billing_provider TEXT NOT NULL DEFAULT '',
                    billing_base_url TEXT NOT NULL DEFAULT '',
                    billing_mode TEXT NOT NULL DEFAULT '',
                    task TEXT NOT NULL DEFAULT '',
                    api_call_count INTEGER NOT NULL DEFAULT 0,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_write_tokens INTEGER NOT NULL DEFAULT 0,
                    reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                    estimated_cost_usd REAL NOT NULL DEFAULT 0,
                    actual_cost_usd REAL NOT NULL DEFAULT 0,
                    first_seen REAL,
                    last_seen REAL,
                    PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT,
                    timestamp REAL NOT NULL
                )
                """)

            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, source, model, started_at, last_activity_at,
                        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
                        cwd, git_repo_root, billing_provider, estimated_cost_usd, actual_cost_usd, title, profile_name
                    ) VALUES (?, 'kanban', ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 'cornelis', 0.0, 0.0, ?, ?)
                    """,
                arguments: [
                    sessionId, model, timestamp - 60, timestamp,
                    inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
                    cwd, cwd, title, profile
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO session_model_usage (
                        session_id, model, billing_provider, billing_base_url, billing_mode, task,
                        api_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
                        estimated_cost_usd, actual_cost_usd, first_seen, last_seen
                    ) VALUES (?, ?, 'cornelis', 'http://cn-ai-01.cornelisnetworks.com:50800/v1/', '', '', 10, ?, ?, ?, ?, 0, 0.0, 0.0, ?, ?)
                    """,
                arguments: [
                    sessionId, model,
                    inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
                    timestamp - 60, timestamp
                ]
            )

            try db.execute(
                sql: "INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', 'Implement stage task', ?)",
                arguments: [sessionId, timestamp - 50]
            )
        }
    }
}
