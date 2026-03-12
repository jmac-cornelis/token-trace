import Foundation
import GRDB

final class CodexReader {

    private let dbPath: String
    private let codexHome: String
    private var dbQueue: DatabaseQueue?

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/state_5.sqlite"
    }()

    static let defaultHome: String = {
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return envHome
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex"
    }()

    init(dbPath: String = CodexReader.defaultPath, codexHome: String = CodexReader.defaultHome) {
        self.dbPath = dbPath
        self.codexHome = codexHome
    }

    func connect() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ReaderError.databaseNotFound(dbPath)
        }

        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
    }

    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        guard let db = dbQueue else {
            return (events: [], newCursor: cursor)
        }

        do {
            let results = try db.read { db -> (events: [UsageEvent], newCursor: String?) in
                var sql = """
                    SELECT
                        id, title, cwd, model_provider, tokens_used,
                        source, created_at, updated_at, git_branch,
                        git_origin_url, cli_version, first_user_message,
                        rollout_path
                    FROM threads
                    WHERE tokens_used > 0
                    """

                var arguments: [DatabaseValueConvertible] = []

                if let cursorValue = cursor, let cursorMs = Int64(cursorValue) {
                    sql += " AND updated_at > ?"
                    arguments.append(cursorMs)
                }

                sql += " ORDER BY updated_at ASC"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

                var events: [UsageEvent] = []
                var latestTimestamp: String?

                for row in rows {
                    let threadId: String = row["id"]
                    let updatedAt: Int64 = row["updated_at"]
                    let tokensUsed: Int = row["tokens_used"] ?? 0
                    let title: String? = row["title"]
                    let cwd: String? = row["cwd"]
                    let modelProvider: String? = row["model_provider"]
                    let firstMessage: String? = row["first_user_message"]
                    let rolloutPath: String? = row["rollout_path"]

                    let projectName = cwd.flatMap { path -> String? in
                        guard !path.isEmpty else { return nil }
                        return URL(fileURLWithPath: path).lastPathComponent
                    }

                    let sessionTitle = title ?? firstMessage.map { msg in
                        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.count > 80 ? String(trimmed.prefix(77)) + "..." : trimmed
                    }

                    let observedAt = Date(timeIntervalSince1970: Double(updatedAt) / 1000.0)

                    // Try to get granular token breakdown from rollout JSONL
                    let rolloutTokens = parseRolloutFile(rolloutPath: rolloutPath, threadId: threadId)

                    let event = UsageEvent(
                        id: "codex-\(threadId)",
                        observedAt: observedAt,
                        source: .codex,
                        sessionID: threadId,
                        sessionTitle: sessionTitle,
                        requestID: nil,
                        projectName: projectName,
                        repoPath: cwd,
                        provider: modelProvider,
                        model: modelProvider,
                        agent: nil,
                        promptTokens: rolloutTokens.input,
                        completionTokens: rolloutTokens.output,
                        cachedReadTokens: 0,
                        cachedWriteTokens: 0,
                        reasoningTokens: rolloutTokens.reasoning,
                        totalTokens: rolloutTokens.hasData ? rolloutTokens.total : tokensUsed,
                        estimatedCostUSD: 0.0
                    )

                    events.append(event)
                    latestTimestamp = String(updatedAt)
                }

                let newCursor = latestTimestamp ?? cursor
                return (events: events, newCursor: newCursor)
            }

            return results
        } catch {
            return (events: [], newCursor: cursor)
        }
    }

    // MARK: - Rollout JSONL Parsing

    private struct RolloutTokens {
        var input: Int = 0
        var output: Int = 0
        var reasoning: Int = 0
        var total: Int = 0
        var hasData: Bool = false
    }

    private func parseRolloutFile(rolloutPath: String?, threadId: String) -> RolloutTokens {
        guard let path = resolveRolloutPath(rolloutPath, threadId: threadId) else {
            return RolloutTokens()
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return RolloutTokens()
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return RolloutTokens()
        }

        var tokens = RolloutTokens()
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // event_msg with token_count payload
            guard let eventType = json["type"] as? String, eventType == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String, payloadType == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let lastUsage = info["last_token_usage"] as? [String: Any] else {
                continue
            }

            let outputTokens = lastUsage["output_tokens"] as? Int ?? 0
            let reasoningTokens = lastUsage["reasoning_output_tokens"] as? Int ?? 0

            tokens.output += outputTokens
            tokens.reasoning += reasoningTokens
            tokens.hasData = true
        }

        // Codex rollouts only track output/reasoning — input is inferred
        // total from threads table is more accurate for the grand total
        tokens.total = tokens.output + tokens.reasoning
        // input = threads.tokens_used - output tokens (rough estimate)
        // We leave input as 0 since rollouts don't track it directly

        return tokens
    }

    private func resolveRolloutPath(_ rolloutPath: String?, threadId: String) -> String? {
        // If rollout_path is set and non-empty, resolve it relative to codex home
        if let rp = rolloutPath, !rp.isEmpty {
            if rp.hasPrefix("/") {
                return rp
            }
            return (codexHome as NSString).appendingPathComponent(rp)
        }

        // No rollout path — try to find it in sessions/ directory by thread ID
        let sessionsDir = (codexHome as NSString).appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir) else {
            return nil
        }

        // Sessions are organized as sessions/{year}/{month}/{day}/{rollout}.jsonl
        // Thread ID might be the rollout filename — search for it
        if let found = findRolloutFile(in: sessionsDir, matching: threadId) {
            return found
        }

        return nil
    }

    private func findRolloutFile(in directory: String, matching threadId: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return nil }

        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".jsonl") && path.contains(threadId) {
                return (directory as NSString).appendingPathComponent(path)
            }
        }
        return nil
    }

    func healthCheck() -> SourceHealth {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database not found at \(dbPath)",
                eventCount: 0
            )
        }

        guard let db = dbQueue else {
            return SourceHealth(
                source: .codex,
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
                        MAX(updated_at) AS last_time,
                        COUNT(*) AS event_count
                    FROM threads
                    WHERE tokens_used > 0
                    """)

                let lastTimeMs: Int64? = row?["last_time"]
                let eventCount: Int = row?["event_count"] ?? 0
                let lastDate = lastTimeMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                return (lastDate, eventCount)
            }

            return SourceHealth(
                source: .codex,
                isHealthy: true,
                lastEventTime: lastTime,
                errorMessage: nil,
                eventCount: count
            )
        } catch {
            return SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: "Database read error: \(error.localizedDescription)",
                eventCount: 0
            )
        }
    }
}
