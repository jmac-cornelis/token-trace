import Testing
import Foundation
@testable import TokenTrace

@Suite("OpenclawReader")
struct OpenclawReaderTests {

    private func makeReader() throws -> (OpenclawReader, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (OpenclawReader(sessionsBasePath: tempDir.path), tempDir)
    }

    private func writeTranscript(at baseDir: URL, agentId: String, sessionId: String, lines: [String]) throws {
        let sessionsDir = baseDir.appendingPathComponent("\(agentId)/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let filePath = sessionsDir.appendingPathComponent("\(sessionId).jsonl")
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: filePath, atomically: true, encoding: .utf8)
    }

    private func makeAssistantEntry(
        inputTokens: Int, outputTokens: Int, totalTokens: Int,
        cacheRead: Int = 0, cacheCreation: Int = 0,
        cost: Double = 0, provider: String = "openai", model: String = "gpt-4",
        timestampMs: Int64? = nil
    ) -> String {
        let ts = timestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        return """
        {"message":{"role":"assistant","provider":"\(provider)","model":"\(model)","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),"total_tokens":\(totalTokens),"cost":{"total":\(cost),"input":0,"output":0}},"durationMs":500,"timestamp":\(ts)},"timestamp":"2026-03-12T10:00:00Z","provider":"\(provider)","model":"\(model)"}
        """
    }

    private func makeUserEntry() -> String {
        return """
        {"message":{"role":"user"},"timestamp":"2026-03-12T10:00:00Z"}
        """
    }

    @Test func fetchEventsFromEmptyDirectory() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
    }

    @Test func fetchEventsFromMissingDirectory() {
        let reader = OpenclawReader(sessionsBasePath: "/nonexistent/path")
        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
    }

    @Test func fetchEventsExtractsAssistantMessages() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeUserEntry(),
            makeAssistantEntry(inputTokens: 150, outputTokens: 75, totalTokens: 225, provider: "anthropic", model: "claude-3"),
            makeUserEntry(),
            makeAssistantEntry(inputTokens: 200, outputTokens: 100, totalTokens: 300),
        ])

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 2)

        #expect(events[0].source == .openclaw)
        #expect(events[0].promptTokens == 150)
        #expect(events[0].completionTokens == 75)
        #expect(events[0].totalTokens == 225)
        #expect(events[0].provider == "anthropic")
        #expect(events[0].model == "claude-3")
        #expect(events[0].sessionID == "session-1")
        #expect(events[0].projectName == "agent-1")

        #expect(events[1].promptTokens == 200)
        #expect(events[1].completionTokens == 100)
        #expect(events[1].totalTokens == 300)
    }

    @Test func fetchEventsSkipsUserMessages() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeUserEntry(),
            makeUserEntry(),
            makeUserEntry(),
        ])

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
    }

    @Test func fetchEventsSkipsZeroTokenMessages() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeAssistantEntry(inputTokens: 0, outputTokens: 0, totalTokens: 0),
        ])

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
    }

    @Test func cacheTokensPopulated() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeAssistantEntry(inputTokens: 100, outputTokens: 50, totalTokens: 150, cacheRead: 30, cacheCreation: 20),
        ])

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 1)
        #expect(events[0].cachedReadTokens == 30)
        #expect(events[0].cachedWriteTokens == 20)
    }

    @Test func costPopulated() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeAssistantEntry(inputTokens: 100, outputTokens: 50, totalTokens: 150, cost: 0.00375),
        ])

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 1)
        #expect(events[0].estimatedCostUSD == 0.00375)
    }

    @Test func cursorSkipsAlreadyProcessedData() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeAssistantEntry(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        ])

        let (firstEvents, cursor) = reader.fetchEvents(since: nil)
        #expect(firstEvents.count == 1)

        let (secondEvents, _) = reader.fetchEvents(since: cursor)
        #expect(secondEvents.isEmpty)
    }

    @Test func cursorPicksUpNewData() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeAssistantEntry(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        ])

        let (_, cursor) = reader.fetchEvents(since: nil)

        let sessionsDir = tempDir.appendingPathComponent("agent-1/sessions")
        let filePath = sessionsDir.appendingPathComponent("session-1.jsonl")
        let newLine = "\n" + makeAssistantEntry(inputTokens: 200, outputTokens: 100, totalTokens: 300) + "\n"
        let handle = try FileHandle(forWritingTo: filePath)
        handle.seekToEndOfFile()
        handle.write(newLine.data(using: .utf8)!)
        handle.closeFile()

        let (newEvents, _) = reader.fetchEvents(since: cursor)
        #expect(newEvents.count == 1)
        #expect(newEvents[0].totalTokens == 300)
    }

    @Test func multipleAgentsAndSessions() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-a", lines: [
            makeAssistantEntry(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        ])
        try writeTranscript(at: tempDir, agentId: "agent-2", sessionId: "session-b", lines: [
            makeAssistantEntry(inputTokens: 200, outputTokens: 100, totalTokens: 300),
            makeAssistantEntry(inputTokens: 300, outputTokens: 150, totalTokens: 450),
        ])

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 3)

        let agent1Events = events.filter { $0.projectName == "agent-1" }
        let agent2Events = events.filter { $0.projectName == "agent-2" }
        #expect(agent1Events.count == 1)
        #expect(agent2Events.count == 2)
    }

    @Test func healthCheckMissingDirectory() {
        let reader = OpenclawReader(sessionsBasePath: "/nonexistent/path")
        let health = reader.healthCheck()
        #expect(!health.isHealthy)
        #expect(health.errorMessage != nil)
    }

    @Test func healthCheckEmptyDirectory() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let health = reader.healthCheck()
        #expect(!health.isHealthy)
        #expect(health.eventCount == 0)
    }

    @Test func healthCheckWithTranscripts() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeTranscript(at: tempDir, agentId: "agent-1", sessionId: "session-1", lines: [
            makeAssistantEntry(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        ])

        let health = reader.healthCheck()
        #expect(health.isHealthy)
        #expect(health.eventCount == 1)
        #expect(health.lastEventTime != nil)
    }
}
