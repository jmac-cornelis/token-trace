import Foundation
import GRDB

// MARK: - ContinueReader

/// Reads token usage from Continue.dev's local SQLite log
/// (`~/.continue/dev_data/devdata.sqlite`, table `tokens_generated`). The
/// autoincrement rowid is the incremental cursor. Continue records no cost,
/// cache, project, session, or request id, so those stay zero/nil.
final class ContinueReader {

    // MARK: - Properties

    private let dbPath: String
    private var dbQueue: DatabaseQueue?

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.continue/dev_data/devdata.sqlite"
    }()

    // MARK: - Initialization

    init(dbPath: String = ContinueReader.defaultPath) {
        self.dbPath = dbPath
    }

    // MARK: - Connection

    func connect() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ReaderError.databaseNotFound(dbPath)
        }

        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    }

    // MARK: - Fetch Events

    /// Cursor is the last seen rowid (`id`) as a string. Returns new events + updated cursor.
    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        guard let db = dbQueue else {
            return (events: [], newCursor: cursor)
        }

        do {
            let results = try db.read { db -> (events: [UsageEvent], newCursor: String?) in
                var sql = """
                    SELECT
                        id,
                        model,
                        provider,
                        tokens_generated,
                        tokens_prompt,
                        timestamp
                    FROM tokens_generated
                    """

                var arguments: [DatabaseValueConvertible] = []

                if let cursorValue = cursor, let cursorId = Int64(cursorValue) {
                    sql += " WHERE id > ?"
                    arguments.append(cursorId)
                }

                sql += " ORDER BY id ASC"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

                var events: [UsageEvent] = []
                var latestId: Int64?

                for row in rows {
                    let rowId: Int64 = row["id"]
                    let model: String? = row["model"]
                    let provider: String? = row["provider"]
                    let completionTokens: Int = row["tokens_generated"] ?? 0
                    let promptTokens: Int = row["tokens_prompt"] ?? 0
                    let totalTokens = promptTokens + completionTokens

                    let observedAt = ContinueReader.parseTimestamp(row["timestamp"]) ?? Date()

                    let event = UsageEvent(
                        id: "continue-\(rowId)",
                        observedAt: observedAt,
                        source: .continue,
                        sessionID: nil,
                        sessionTitle: nil,
                        requestID: nil,
                        projectName: nil,
                        repoPath: nil,
                        provider: provider,
                        model: model,
                        agent: nil,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens,
                        cachedReadTokens: 0,
                        cachedWriteTokens: 0,
                        reasoningTokens: 0,
                        totalTokens: totalTokens,
                        estimatedCostUSD: 0,
                        lastPrompt: nil
                    )

                    events.append(event)
                    latestId = rowId
                }

                let newCursor = latestId.map(String.init) ?? cursor
                return (events: events, newCursor: newCursor)
            }

            return results
        } catch {
            return (events: [], newCursor: cursor)
        }
    }

    // MARK: - Health Check

    func healthCheck() -> SourceHealth {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return SourceHealth(
                source: .continue,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database not found at \(dbPath)",
                eventCount: 0
            )
        }

        guard let db = dbQueue else {
            return SourceHealth(
                source: .continue,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Not connected to database",
                eventCount: 0
            )
        }

        do {
            let (lastTime, count) = try db.read { db -> (Date?, Int) in
                let row = try Row.fetchOne(db, sql: """
                    SELECT
                        MAX(timestamp) AS last_time,
                        COUNT(*) AS event_count
                    FROM tokens_generated
                    """)

                let lastTimeString: String? = row?["last_time"]
                let eventCount: Int = row?["event_count"] ?? 0
                let lastDate = lastTimeString.flatMap(ContinueReader.parseTimestamp)
                return (lastDate, eventCount)
            }

            return SourceHealth(
                source: .continue,
                isHealthy: true,
                lastEventTime: lastTime,
                errorMessage: nil,
                eventCount: count
            )
        } catch {
            return SourceHealth(
                source: .continue,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database read error: \(error.localizedDescription)",
                eventCount: 0
            )
        }
    }

    // MARK: - Private Helpers

    /// Continue stores `timestamp` as SQLite CURRENT_TIMESTAMP text ("yyyy-MM-dd HH:mm:ss",
    /// in UTC). Fall back to ISO-8601 in case a future Continue version changes the format.
    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let sqlite = DateFormatter()
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlite.timeZone = TimeZone(identifier: "UTC")
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        if let date = sqlite.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }
}
