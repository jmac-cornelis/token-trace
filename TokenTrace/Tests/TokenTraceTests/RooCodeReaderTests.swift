import Testing
import Foundation
@testable import TokenTrace

@Suite("RooCodeReader")
struct RooCodeReaderTests {

    private final class TestSnapshotStore: RooTaskSnapshotStore {
        var snapshotsByTaskID: [String: RooTaskSnapshot] = [:]

        func snapshots(for taskIDs: [String]) throws -> [String: RooTaskSnapshot] {
            snapshotsByTaskID.filter { taskIDs.contains($0.key) }
        }

        func saveSnapshots(_ snapshots: [RooTaskSnapshot]) throws {
            for snapshot in snapshots {
                snapshotsByTaskID[snapshot.taskID] = snapshot
            }
        }
    }

    private func makeReader() throws -> (RooCodeReader, TestSnapshotStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tasksDir = tempDir.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        let snapshotStore = TestSnapshotStore()
        return (RooCodeReader(basePath: tempDir.path, snapshotStore: snapshotStore), snapshotStore, tempDir)
    }

    @Test func fetchEventsFromEmptyIndex() throws {
        let (reader, _, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeIndex(at: tempDir, content: "{\"version\":1,\"entries\":[]}")

        let (events, cursor) = try reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
        #expect(cursor == nil)
    }

    @Test func bootstrapScanStoresBaselinesWithoutEvents() throws {
        let (reader, snapshotStore, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-001"
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(now),"task":"Test task","tokensIn":400,"tokensOut":200,"totalCost":1.5,"workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis","cacheWrites":25,"cacheReads":50}]}
        """)

        let (events, cursor) = try reader.fetchEvents(since: nil)
        #expect(events.isEmpty)
        #expect(cursor == makeCursor(now))

        let snapshot = try #require(snapshotStore.snapshots(for: [taskId])[taskId])
        #expect(snapshot.tokensIn == 400)
        #expect(snapshot.tokensOut == 200)
        #expect(snapshot.cacheWrites == 25)
        #expect(snapshot.cacheReads == 50)
        #expect(snapshot.totalCost == 1.5)
        #expect(snapshot.lastTimestamp == now)
    }

    @Test func bootstrapScanBackfillsTodaysApiUsage() throws {
        let (reader, snapshotStore, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-bootstrap"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let todayTs = Int64(startOfToday.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let yesterdayTs = Int64(startOfToday.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(now),"task":"Bootstrap task","tokensIn":1000,"tokensOut":500,"totalCost":4.5,"workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis","cacheWrites":4,"cacheReads":9}]}
        """)
        try writeMessages(at: tempDir, taskID: taskId, content: """
        [
          {"ts":\(yesterdayTs),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":999,\\"tokensOut\\":888,\\"cacheWrites\\":7,\\"cacheReads\\":6,\\"cost\\":1.5}"},
          {"ts":\(todayTs),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":120,\\"tokensOut\\":45,\\"cacheWrites\\":3,\\"cacheReads\\":8,\\"cost\\":0.75}"},
          {"ts":\(todayTs + 1000),"type":"say","say":"api_req_started","text":"{\\"tokensIn\\":30,\\"tokensOut\\":15,\\"cacheWrites\\":1,\\"cacheReads\\":2,\\"cost\\":0.25}"}
        ]
        """)

        let (events, cursor) = try reader.fetchEvents(since: nil)
        #expect(cursor == makeCursor(now))
        #expect(events.count == 1)

        let event = try #require(events.first)
        #expect(event.id == "\(taskId)-bootstrap-\(Int64(startOfToday.timeIntervalSince1970 * 1000))")
        #expect(event.promptTokens == 150)
        #expect(event.completionTokens == 60)
        #expect(event.totalTokens == 210)
        #expect(event.cachedWriteTokens == 4)
        #expect(event.cachedReadTokens == 10)
        #expect(event.estimatedCostUSD == 1.0)

        let snapshot = try #require(snapshotStore.snapshots(for: [taskId])[taskId])
        #expect(snapshot.tokensIn == 1000)
        #expect(snapshot.tokensOut == 500)
        #expect(snapshot.lastTimestamp == now)
    }

    @Test func fetchEventsEmitsDeltasForExistingTask() throws {
        let (reader, _, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-delta"
        let firstTs = Int64(Date().timeIntervalSince1970 * 1000)
        let secondTs = firstTs + 1_000

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(firstTs),"task":"Delta task","tokensIn":400,"tokensOut":200,"totalCost":1.5,"workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis","cacheWrites":25,"cacheReads":50}]}
        """)

        let (_, cursor) = try reader.fetchEvents(since: nil)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(secondTs),"task":"Delta task","tokensIn":550,"tokensOut":260,"totalCost":2.0,"workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis","cacheWrites":35,"cacheReads":80}]}
        """)

        let (events, newCursor) = try reader.fetchEvents(since: cursor)
        #expect(newCursor == makeCursor(secondTs))
        #expect(events.count == 1)
        #expect(events.first?.id == "\(taskId)-\(secondTs)")
        #expect(events.first?.promptTokens == 150)
        #expect(events.first?.completionTokens == 60)
        #expect(events.first?.totalTokens == 210)
        #expect(events.first?.cachedWriteTokens == 10)
        #expect(events.first?.cachedReadTokens == 30)
        #expect(events.first?.estimatedCostUSD == 0.5)
    }

    @Test func fetchEventsSkipsZeroTokenTasks() throws {
        let (reader, _, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cursor = makeCursor(now - 1)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[
            {"id":"task-zero","ts":\(now),"task":"Zero tokens","tokensIn":0,"tokensOut":0,"workspace":"/tmp/proj","mode":"code","apiConfigName":"test"},
            {"id":"task-nonzero","ts":\(now + 1000),"task":"Has tokens","tokensIn":100,"tokensOut":50,"workspace":"/tmp/proj","mode":"code","apiConfigName":"test"}
        ]}
        """)

        let (events, _) = try reader.fetchEvents(since: cursor)
        #expect(events.count == 1)
        #expect(events.first?.sessionID == "task-nonzero")
        #expect(events.first?.totalTokens == 150)
    }

    @Test func fetchEventsClampsCounterResets() throws {
        let (reader, _, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-reset"
        let firstTs = Int64(Date().timeIntervalSince1970 * 1000)
        let secondTs = firstTs + 1_000

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(firstTs),"task":"Reset task","tokensIn":500,"tokensOut":200,"totalCost":1.0,"workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis","cacheWrites":12,"cacheReads":20}]}
        """)

        let (_, cursor) = try reader.fetchEvents(since: nil)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(secondTs),"task":"Reset task","tokensIn":450,"tokensOut":260,"totalCost":1.25,"workspace":"/tmp/project","mode":"code","apiConfigName":"cornelis","cacheWrites":10,"cacheReads":25}]}
        """)

        let (events, _) = try reader.fetchEvents(since: cursor)
        #expect(events.count == 1)
        #expect(events.first?.promptTokens == 0)
        #expect(events.first?.completionTokens == 60)
        #expect(events.first?.cachedWriteTokens == 0)
        #expect(events.first?.cachedReadTokens == 5)
        #expect(events.first?.estimatedCostUSD == 0.25)
        #expect(events.first?.totalTokens == 60)
    }

    @Test func cursorFiltersOldTasks() throws {
        let (reader, _, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldTs = Int64(Date().timeIntervalSince1970 * 1000) - 100_000
        let newTs = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[
            {"id":"old-task","ts":\(oldTs),"task":"Old","tokensIn":100,"tokensOut":50,"workspace":"/tmp/old","mode":"code","apiConfigName":"test"},
            {"id":"new-task","ts":\(newTs),"task":"New","tokensIn":200,"tokensOut":100,"workspace":"/tmp/new","mode":"code","apiConfigName":"test"}
        ]}
        """)

        let cursor = makeCursor(oldTs)
        let (events, _) = try reader.fetchEvents(since: cursor)
        #expect(events.count == 1)
        #expect(events.first?.sessionID == "new-task")
    }

    @Test func eventFieldsPopulatedCorrectly() throws {
        let (reader, _, tempDir) = try makeReader()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskId = "task-fields"
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try writeIndex(at: tempDir, content: """
        {"version":1,"entries":[{"id":"\(taskId)","ts":\(now),"task":"My task description","tokensIn":500,"tokensOut":200,"workspace":"/Users/john/code/my-project","mode":"architect","apiConfigName":"developer-opus","cacheWrites":10,"cacheReads":20,"totalCost":2.25}]}
        """)

        let (events, _) = try reader.fetchEvents(since: makeCursor(now - 1))
        #expect(events.count == 1)

        let event = events[0]
        #expect(event.source == .roo)
        #expect(event.sessionID == taskId)
        #expect(event.sessionTitle == "My task description")
        #expect(event.projectName == "my-project")
        #expect(event.repoPath == "/Users/john/code/my-project")
        #expect(event.provider == "developer-opus")
        #expect(event.model == "developer-opus")
        #expect(event.agent == "architect")
        #expect(event.promptTokens == 500)
        #expect(event.completionTokens == 200)
        #expect(event.cachedReadTokens == 20)
        #expect(event.cachedWriteTokens == 10)
        #expect(event.estimatedCostUSD == 2.25)
    }

    @Test func healthCheckWithMissingIndex() {
        let badReader = RooCodeReader(basePath: "/nonexistent/path")
        let health = badReader.healthCheck()
        #expect(!health.isHealthy)
        #expect(health.errorMessage != nil)
    }

    @Test func healthCheckWithValidIndex() throws {
        let (reader, _, tempDir) = try makeReader()
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

    private func writeMessages(at tempDir: URL, taskID: String, content: String) throws {
        let taskDir = tempDir.appendingPathComponent("tasks/\(taskID)")
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let messagesPath = taskDir.appendingPathComponent("ui_messages.json")
        try content.write(to: messagesPath, atomically: true, encoding: .utf8)
    }

    private func makeCursor(_ timestamp: Int64) -> String {
        "{\"lastTimestamp\":\(timestamp)}"
    }
}
