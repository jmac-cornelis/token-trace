import Foundation

// Owns the source readers as actor-isolated state so their blocking file/SQLite work
// runs off the main thread. The readers are non-Sendable classes but never escape the
// actor, so they never need to be Sendable; collect() returns only Sendable results.
actor CollectionEngine {
    private let openCodeReader = OpenCodeReader()
    private let codexReader = CodexReader()
    private let openclawReader = OpenclawReader()
    private let continueReader = ContinueReader()
    private let db: DatabaseManager

    struct Outcome: Sendable {
        var openCodeHealth: SourceHealth?
        var codexHealth: SourceHealth?
        var openclawHealth: SourceHealth?
        var continueHealth: SourceHealth?
        var insertedCount = 0
    }

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    func collect() async -> Outcome {
        var outcome = Outcome()
        outcome.insertedCount += await runOpenCode(into: &outcome)
        outcome.insertedCount += await runCodex(into: &outcome)
        outcome.insertedCount += await runOpenclaw(into: &outcome)
        outcome.insertedCount += await runContinue(into: &outcome)
        return outcome
    }

    private func runOpenCode(into outcome: inout Outcome) async -> Int {
        do {
            try openCodeReader.connect()
            let cursor = try await db.getCursor(for: .opencode)
            let (events, newCursor) = openCodeReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try await db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try await db.setCursor(for: .opencode, cursor: newCursor)
            }
            outcome.openCodeHealth = openCodeReader.healthCheck()
            return events.count
        } catch {
            outcome.openCodeHealth = SourceHealth(
                source: .opencode,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
            return 0
        }
    }

    private func runCodex(into outcome: inout Outcome) async -> Int {
        do {
            try codexReader.connect()
            let cursor = try await db.getCursor(for: .codex)
            let (events, newCursor) = codexReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try await db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try await db.setCursor(for: .codex, cursor: newCursor)
            }
            outcome.codexHealth = codexReader.healthCheck()
            return events.count
        } catch {
            outcome.codexHealth = SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
            return 0
        }
    }

    private func runOpenclaw(into outcome: inout Outcome) async -> Int {
        do {
            let cursor = try await db.getCursor(for: .openclaw)
            let (events, newCursor) = openclawReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try await db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try await db.setCursor(for: .openclaw, cursor: newCursor)
            }
            outcome.openclawHealth = openclawReader.healthCheck()
            return events.count
        } catch {
            outcome.openclawHealth = SourceHealth(
                source: .openclaw,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
            return 0
        }
    }

    private func runContinue(into outcome: inout Outcome) async -> Int {
        do {
            try continueReader.connect()
            let cursor = try await db.getCursor(for: .continue)
            let (events, newCursor) = continueReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try await db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try await db.setCursor(for: .continue, cursor: newCursor)
            }
            outcome.continueHealth = continueReader.healthCheck()
            return events.count
        } catch {
            outcome.continueHealth = SourceHealth(
                source: .continue,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
            return 0
        }
    }
}
