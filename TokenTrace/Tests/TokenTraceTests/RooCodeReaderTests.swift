import Testing
import Foundation
@testable import TokenTrace

@Suite("RooCodeReader")
struct RooCodeReaderTests {

    private func makeReader() throws -> (RooCodeReader, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tasksDir = tempDir.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        return (RooCodeReader(basePath: tempDir.path), tempDir)
    }

    @Test func fetchEventsFromEmptyIndex() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeIndex(at: tempDir, content: "{\"version\":1,\"entries\":[]}")

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
    }

    @Test func fetchEventsComputesDeltasFromCumulativeTokens() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-001"
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(now),"task":"Test task","workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis"}]}
        """)

        try writeTaskMessages(at: tempDir, taskId: taskId, messages: """
        [
            {"ts":\(now),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":100,\\"tokensOut\\":50,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"},
            {"ts":\(now + 1000),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":250,\\"tokensOut\\":120,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"},
            {"ts":\(now + 2000),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":400,\\"tokensOut\\":200,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"}
        ]
        """)

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 3)

        #expect(events[0].promptTokens == 100)
        #expect(events[0].completionTokens == 50)
        #expect(events[0].totalTokens == 150)

        #expect(events[1].promptTokens == 150)
        #expect(events[1].completionTokens == 70)
        #expect(events[1].totalTokens == 220)

        #expect(events[2].promptTokens == 150)
        #expect(events[2].completionTokens == 80)
        #expect(events[2].totalTokens == 230)
    }

    @Test func fetchEventsSkipsZeroDeltaRequests() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-002"
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(now),"task":"Zero delta","workspace":"/tmp/proj","mode":"code","apiConfigName":"test"}]}
        """)

        try writeTaskMessages(at: tempDir, taskId: taskId, messages: """
        [
            {"ts":\(now),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":100,\\"tokensOut\\":50,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"},
            {"ts":\(now + 1000),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":100,\\"tokensOut\\":50,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"}
        ]
        """)

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 1)
    }

    @Test func cursorFiltersOldTasks() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldTs = Int64(Date().timeIntervalSince1970 * 1000) - 100_000
        let newTs = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[
            {"id":"old-task","ts":\(oldTs),"task":"Old","workspace":"/tmp/old","mode":"code","apiConfigName":"test"},
            {"id":"new-task","ts":\(newTs),"task":"New","workspace":"/tmp/new","mode":"code","apiConfigName":"test"}
        ]}
        """)

        try writeTaskMessages(at: tempDir, taskId: "old-task", messages: """
        [{"ts":\(oldTs),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":100,\\"tokensOut\\":50,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"}]
        """)
        try writeTaskMessages(at: tempDir, taskId: "new-task", messages: """
        [{"ts":\(newTs),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":200,\\"tokensOut\\":100,\\"cacheWrites\\":0,\\"cacheReads\\":0,\\"cost\\":0}"}]
        """)

        let cursor = "{\"lastTimestamp\":\(oldTs)}"
        let (events, _) = reader.fetchEvents(since: cursor)
        #expect(events.count == 1)
        #expect(events.first?.sessionID == "new-task")
    }

    @Test func eventFieldsPopulatedCorrectly() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-fields"
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(now),"task":"My task description","workspace":"/Users/john/code/my-project","mode":"architect","apiConfigName":"developer-opus"}]}
        """)

        try writeTaskMessages(at: tempDir, taskId: taskId, messages: """
        [{"ts":\(now),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":500,\\"tokensOut\\":200,\\"cacheWrites\\":10,\\"cacheReads\\":20,\\"cost\\":0}"}]
        """)

        let (events, _) = reader.fetchEvents(since: nil)
        #expect(events.count == 1)

        let event = events[0]
        #expect(event.source == .roo)
        #expect(event.sessionID == taskId)
        #expect(event.sessionTitle == "My task description")
        #expect(event.projectName == "my-project")
        #expect(event.repoPath == "/Users/john/code/my-project")
        #expect(event.provider == "developer-opus")
        #expect(event.agent == "architect")
        #expect(event.cachedReadTokens == 20)
        #expect(event.cachedWriteTokens == 10)
    }

    @Test func healthCheckWithMissingIndex() {
        let badReader = RooCodeReader(basePath: "/nonexistent/path")
        let health = badReader.healthCheck()
        #expect(!health.isHealthy)
        #expect(health.errorMessage != nil)
    }

    @Test func healthCheckWithValidIndex() throws {
        let (reader, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"t1","ts":\(now),"task":"Test","workspace":"/tmp","mode":"code","apiConfigName":"test"}]}
        """)

        let health = reader.healthCheck()
        #expect(health.isHealthy)
        #expect(health.eventCount == 1)
        #expect(health.lastEventTime != nil)
    }

    private func writeIndex(at tempDir: URL, content: String) throws {
        let indexPath = tempDir.appendingPathComponent("tasks/_index.json")
        try content.write(to: indexPath, atomically: true, encoding: .utf8)
    }

    private func writeTaskMessages(at tempDir: URL, taskId: String, messages: String) throws {
        let taskDir = tempDir.appendingPathComponent("tasks/\(taskId)")
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let messagesPath = taskDir.appendingPathComponent("ui_messages.json")
        try messages.write(to: messagesPath, atomically: true, encoding: .utf8)
    }
}
