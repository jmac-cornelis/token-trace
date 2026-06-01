import Testing
import Foundation
import GRDB
@testable import TokenTrace

@Suite("ContinueReader")
struct ContinueReaderTests {

    private func makeReader() throws -> (ContinueReader, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("devdata.sqlite").path
        try createMockContinueDB(at: dbPath)
        return (ContinueReader(dbPath: dbPath), tempDir)
    }

    @Test func fetchEventsReturnsTokenRows() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, cursor) = reader.fetchEvents(since: nil)
        #expect(events.count == 2)
        #expect(cursor == "2")

        let first = events[0]
        #expect(first.source == .continue)
        #expect(first.promptTokens == 1000)
        #expect(first.completionTokens == 500)
        #expect(first.totalTokens == 1500)
        #expect(first.model == "gpt-4o")
        #expect(first.provider == "openai")
        #expect(first.id == "continue-1")
    }

    @Test func cursorFiltersOldRows() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (allEvents, cursor) = reader.fetchEvents(since: nil)
        #expect(allEvents.count == 2)

        let (newEvents, _) = reader.fetchEvents(since: cursor)
        #expect(newEvents.isEmpty)
    }

    @Test func timestampParsedAsUTC() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try reader.connect()

        let (events, _) = reader.fetchEvents(since: nil)
        let expected = ISO8601DateFormatter().date(from: "2026-04-15T12:00:00Z")
        #expect(events[0].observedAt == expected)
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
        let reader = ContinueReader(dbPath: "/nonexistent/devdata.sqlite")
        let health = reader.healthCheck()
        #expect(!health.isHealthy)
    }

    @Test func connectThrowsForMissingDB() {
        let reader = ContinueReader(dbPath: "/nonexistent/devdata.sqlite")
        #expect(throws: (any Error).self) { try reader.connect() }
    }

    private func createMockContinueDB(at path: String) throws {
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE tokens_generated (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    model TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    tokens_generated INTEGER NOT NULL,
                    tokens_prompt INTEGER NOT NULL DEFAULT 0,
                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: """
                INSERT INTO tokens_generated (model, provider, tokens_generated, tokens_prompt, timestamp)
                VALUES ('gpt-4o', 'openai', 500, 1000, '2026-04-15 12:00:00')
                """)
            try db.execute(sql: """
                INSERT INTO tokens_generated (model, provider, tokens_generated, tokens_prompt, timestamp)
                VALUES ('claude-3-5-sonnet', 'anthropic', 800, 300, '2026-04-15 12:05:00')
                """)
        }
    }
}
