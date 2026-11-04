import Foundation

// MARK: - RemoteUsageReader

/// Collects token usage from a remote SSH host where Hermes Agent profiles
/// and OpenCode workers execute.
///
/// Queries remote SQLite databases in read-only mode over a single non-interactive
/// SSH invocation:
/// - `~/.hermes/state.db` and `~/.hermes/profiles/*/state.db`
/// - `/scratch/<user>/opencode/data/opencode/opencode.db` and `~/.local/share/opencode/opencode.db`
final class RemoteUsageReader {

    private let host: String
    private let enabled: Bool

    static let defaultHost = "ai-devsrvr-11"

    init(host: String = RemoteUsageReader.defaultHost, enabled: Bool = true) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.enabled = enabled && !self.host.isEmpty
    }

    struct CursorState: Codable {
        var hermesCursors: [String: Double] = [:]
        var opencodeCursors: [String: Int64] = [:]
    }

    private struct RemotePayload: Decodable {
        let hermesEvents: [RemoteHermesRow]
        let hermesCursors: [String: Double]
        let opencodeEvents: [RemoteOpenCodeRow]
        let opencodeCursors: [String: Int64]
    }

    private struct RemoteHermesRow: Decodable {
        let dbPath: String
        let profile: String
        let sessionId: String
        let model: String?
        let provider: String?
        let task: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let reasoningTokens: Int
        let estimatedCostUsd: Double
        let actualCostUsd: Double
        let eventTs: Double
        let title: String?
        let cwd: String?
        let repoRoot: String?
        let lastPrompt: String?
    }

    private struct RemoteOpenCodeRow: Decodable {
        let dbPath: String
        let messageId: String
        let sessionId: String
        let timeCreated: Int64
        let title: String?
        let directory: String?
        let projectName: String?
        let worktree: String?
        let modelId: String?
        let providerId: String?
        let agent: String?
        let tokensTotal: Int
        let tokensInput: Int
        let tokensOutput: Int
        let tokensReasoning: Int
        let cacheRead: Int
        let cacheWrite: Int
        let cost: Double
        let lastPrompt: String?
    }

    static func decodeCursor(_ cursor: String?) -> CursorState {
        guard let cursor, !cursor.isEmpty,
              let data = cursor.data(using: .utf8),
              let state = try? JSONDecoder().decode(CursorState.self, from: data) else {
            return CursorState()
        }
        return state
    }

    static func encodeCursor(_ state: CursorState) -> String? {
        guard let data = try? JSONEncoder().encode(state),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        guard enabled else {
            return ([], cursor)
        }

        let cursorState = Self.decodeCursor(cursor)
        guard let cursorJSON = Self.encodeCursor(cursorState) else {
            return ([], cursor)
        }

        guard let payload = runSSHQuery(cursorJSON: cursorJSON) else {
            return ([], cursor)
        }

        var events: [UsageEvent] = []
        let hostTag = host

        for row in payload.hermesEvents {
            let inputTokens = max(0, row.inputTokens)
            let outputTokens = max(0, row.outputTokens)
            let cacheRead = max(0, row.cacheReadTokens)
            let cacheWrite = max(0, row.cacheWriteTokens)
            let reasoning = max(0, row.reasoningTokens)
            let promptTokens = inputTokens + cacheRead + cacheWrite
            let totalTokens = promptTokens + outputTokens + reasoning
            guard totalTokens > 0 else { continue }

            let observedAt = Date(timeIntervalSince1970: row.eventTs)
            let reportedCost = row.actualCostUsd > 0 ? row.actualCostUsd : row.estimatedCostUsd
            let cost = OpenCodeReader.resolveCost(
                reportedCost: reportedCost,
                model: row.model,
                observedAt: observedAt,
                promptTokens: promptTokens,
                completionTokens: outputTokens,
                cachedReadTokens: cacheRead,
                cachedWriteTokens: cacheWrite,
                reasoningTokens: reasoning
            )

            let repoPath = OpenCodeReader.resolveRepoPath(
                worktree: row.repoRoot,
                sessionDirectory: row.cwd
            )
            let projectName = OpenCodeReader.resolveProjectName(
                projectName: nil,
                repoPath: repoPath
            )

            let profile = row.profile.isEmpty ? "default" : row.profile
            let agentLabel = row.task.isEmpty ? profile : "\(profile):\(row.task)"
            let modelTag = row.model ?? "unknown"
            let taskTag = row.task.isEmpty ? "main" : row.task
            let eventId = "hermes-remote-\(hostTag)-\(profile)-\(row.sessionId)-\(modelTag)-\(taskTag)"

            events.append(UsageEvent(
                id: eventId,
                observedAt: observedAt,
                source: .hermes,
                sessionID: "hermes-remote-\(hostTag)-\(profile)-\(row.sessionId)",
                sessionTitle: row.title,
                requestID: eventId,
                projectName: projectName ?? profile,
                repoPath: repoPath,
                provider: (row.provider?.isEmpty == false) ? row.provider : "cornelis",
                model: row.model,
                agent: agentLabel,
                promptTokens: inputTokens,
                completionTokens: outputTokens,
                cachedReadTokens: cacheRead,
                cachedWriteTokens: cacheWrite,
                reasoningTokens: reasoning,
                totalTokens: totalTokens,
                estimatedCostUSD: cost,
                lastPrompt: row.lastPrompt
            ))
        }

        for row in payload.opencodeEvents {
            let tokensInput = max(0, row.tokensInput)
            let tokensOutput = max(0, row.tokensOutput)
            let tokensReasoning = max(0, row.tokensReasoning)
            let cacheRead = max(0, row.cacheRead)
            let cacheWrite = max(0, row.cacheWrite)
            let rawTotal = max(0, row.tokensTotal)
            let tokensTotal = rawTotal > 0
                ? rawTotal
                : (tokensInput + tokensOutput + tokensReasoning + cacheRead + cacheWrite)
            guard tokensTotal > 0 else { continue }

            let observedAt = Date(timeIntervalSince1970: Double(row.timeCreated) / 1000.0)
            let cost = OpenCodeReader.resolveCost(
                reportedCost: row.cost,
                model: row.modelId,
                observedAt: observedAt,
                promptTokens: tokensInput + cacheRead + cacheWrite,
                completionTokens: tokensOutput,
                cachedReadTokens: cacheRead,
                cachedWriteTokens: cacheWrite,
                reasoningTokens: tokensReasoning
            )

            let repoPath = OpenCodeReader.resolveRepoPath(
                worktree: row.worktree,
                sessionDirectory: row.directory
            )
            let projectName = OpenCodeReader.resolveProjectName(
                projectName: row.projectName,
                repoPath: repoPath
            )

            let eventId = "opencode-remote-\(hostTag)-\(row.messageId)"
            events.append(UsageEvent(
                id: eventId,
                observedAt: observedAt,
                source: .opencode,
                sessionID: "opencode-remote-\(hostTag)-\(row.sessionId)",
                sessionTitle: row.title,
                requestID: row.messageId,
                projectName: projectName,
                repoPath: repoPath,
                provider: row.providerId,
                model: row.modelId,
                agent: row.agent,
                promptTokens: tokensInput,
                completionTokens: tokensOutput,
                cachedReadTokens: cacheRead,
                cachedWriteTokens: cacheWrite,
                reasoningTokens: tokensReasoning,
                totalTokens: tokensTotal,
                estimatedCostUSD: cost,
                lastPrompt: row.lastPrompt
            ))
        }

        var nextCursor = cursorState
        for (k, v) in payload.hermesCursors {
            nextCursor.hermesCursors[k] = v
        }
        for (k, v) in payload.opencodeCursors {
            nextCursor.opencodeCursors[k] = v
        }

        events.sort { $0.observedAt < $1.observedAt }
        return (events: events, newCursor: Self.encodeCursor(nextCursor) ?? cursor)
    }

    private func runSSHQuery(cursorJSON: String) -> RemotePayload? {
        guard !host.hasPrefix("-") else { return nil }
        let cursorB64 = Data(cursorJSON.utf8).base64EncodedString()
        let script = Self.remotePythonScript(cursorB64: cursorB64)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "--",
            host,
            "python3", "-"
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        var outputData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { [weak process] in
            if let process, process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20.0, execute: watchdog)

        if let scriptData = script.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: scriptData)
        }
        try? stdinPipe.fileHandleForWriting.close()

        readGroup.wait()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0, !outputData.isEmpty else {
            return nil
        }

        return try? JSONDecoder().decode(RemotePayload.self, from: outputData)
    }

    private static func remotePythonScript(cursorB64: String) -> String {
        """
        import base64, glob, json, os, sqlite3, sys
        state = json.loads(base64.b64decode('\(cursorB64)').decode('utf-8'))
        h_cur = dict(state.get('hermesCursors') or {})
        o_cur = dict(state.get('opencodeCursors') or {})
        home = os.path.expanduser('~')
        user = os.path.basename(home)
        h_events, o_events = [], []
        h_paths = sorted(set(glob.glob(f'{home}/.hermes/profiles/*/state.db') + [f'{home}/.hermes/state.db']))
        for p in h_paths:
            if not os.path.exists(p): continue
            since = float(h_cur.get(p, 0.0))
            parts = p.split('/')
            prof = parts[parts.index('profiles') + 1] if 'profiles' in parts and parts.index('profiles') + 1 < len(parts) - 1 else 'default'
            try:
                c = sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=2.0)
                c.row_factory = sqlite3.Row
                rows = c.execute('''
                    SELECT u.session_id, u.model, u.billing_provider, u.task,
                           COALESCE(u.input_tokens, 0) AS input_tokens,
                           COALESCE(u.output_tokens, 0) AS output_tokens,
                           COALESCE(u.cache_read_tokens, 0) AS cache_read_tokens,
                           COALESCE(u.cache_write_tokens, 0) AS cache_write_tokens,
                           COALESCE(u.reasoning_tokens, 0) AS reasoning_tokens,
                           COALESCE(u.estimated_cost_usd, 0.0) AS estimated_cost_usd,
                           COALESCE(u.actual_cost_usd, 0.0) AS actual_cost_usd,
                           COALESCE(u.last_seen, s.last_activity_at, s.started_at, 0.0) AS event_ts,
                           s.title, s.cwd, s.git_repo_root, s.profile_name,
                           (SELECT m.content FROM messages m WHERE m.session_id = s.id AND m.role = 'user' AND m.content IS NOT NULL ORDER BY m.timestamp DESC LIMIT 1) AS last_prompt
                    FROM session_model_usage u
                    JOIN sessions s ON s.id = u.session_id
                    WHERE (COALESCE(u.input_tokens, 0) + COALESCE(u.output_tokens, 0) + COALESCE(u.cache_read_tokens, 0) + COALESCE(u.cache_write_tokens, 0) + COALESCE(u.reasoning_tokens, 0)) > 0
                      AND COALESCE(u.last_seen, s.last_activity_at, s.started_at, 0.0) > ?
                    ORDER BY event_ts ASC
                ''', (since,)).fetchall()
                mx = since
                for r in rows:
                    ts = float(r['event_ts'] or 0.0)
                    if ts > mx: mx = ts
                    h_events.append({
                        'dbPath': p,
                        'profile': r['profile_name'] or prof,
                        'sessionId': r['session_id'],
                        'model': r['model'],
                        'provider': r['billing_provider'],
                        'task': r['task'] or '',
                        'inputTokens': int(r['input_tokens']),
                        'outputTokens': int(r['output_tokens']),
                        'cacheReadTokens': int(r['cache_read_tokens']),
                        'cacheWriteTokens': int(r['cache_write_tokens']),
                        'reasoningTokens': int(r['reasoning_tokens']),
                        'estimatedCostUsd': float(r['estimated_cost_usd']),
                        'actualCostUsd': float(r['actual_cost_usd']),
                        'eventTs': ts,
                        'title': r['title'],
                        'cwd': r['cwd'],
                        'repoRoot': r['git_repo_root'],
                        'lastPrompt': (r['last_prompt'][:200] if r['last_prompt'] else None)
                    })
                if mx > since: h_cur[p] = mx
                c.close()
            except Exception:
                pass
        o_paths = []
        for cand in [f'/scratch/{user}/opencode/data/opencode/opencode.db', f'{home}/.local/share/opencode/opencode.db', f'{home}/.local/opencode-2x/data/opencode/opencode.db']:
            if os.path.exists(cand) and cand not in o_paths:
                o_paths.append(cand)
        for p in o_paths:
            since = int(o_cur.get(p, 0))
            try:
                c = sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=3.0)
                c.row_factory = sqlite3.Row
                tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
                if 'session_message' in tables and 'session_v2' in tables:
                    sql = '''
                        WITH latest_user AS (
                            SELECT session_id, substr(json_extract(data, '$.text'), 1, 200) AS prompt_text,
                                   ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY time_created DESC) AS rn
                            FROM session_message
                            WHERE type = 'user'
                        )
                        SELECT m.id AS message_id, m.session_id, m.time_created,
                               COALESCE(m.time_updated, m.time_created) AS cursor_ts,
                               s.title, s.directory, p.name AS project_name, p.worktree,
                               COALESCE(json_extract(m.data, '$.model.id'), json_extract(m.data, '$.modelID')) AS model_id,
                               COALESCE(json_extract(m.data, '$.model.providerID'), json_extract(m.data, '$.providerID')) AS provider_id,
                               json_extract(m.data, '$.agent') AS agent,
                               COALESCE(json_extract(m.data, '$.tokens.total'), 0) AS tokens_total,
                               COALESCE(json_extract(m.data, '$.tokens.input'), 0) AS tokens_input,
                               COALESCE(json_extract(m.data, '$.tokens.output'), 0) AS tokens_output,
                               COALESCE(json_extract(m.data, '$.tokens.reasoning'), 0) AS tokens_reasoning,
                               COALESCE(json_extract(m.data, '$.tokens.cache.read'), 0) AS cache_read,
                               COALESCE(json_extract(m.data, '$.tokens.cache.write'), 0) AS cache_write,
                               COALESCE(json_extract(m.data, '$.cost'), 0.0) AS cost,
                               lu.prompt_text AS last_prompt
                        FROM session_message m
                        JOIN session_v2 s ON m.session_id = s.id
                        LEFT JOIN project p ON s.project_id = p.id
                        LEFT JOIN latest_user lu ON lu.session_id = m.session_id AND lu.rn = 1
                        WHERE m.type = 'assistant' AND COALESCE(m.time_updated, m.time_created) > ? AND json_extract(m.data, '$.tokens') IS NOT NULL
                        ORDER BY m.time_created ASC
                    '''
                else:
                    sql = '''
                        SELECT m.id AS message_id, m.session_id, m.time_created,
                               m.time_created AS cursor_ts,
                               s.title, s.directory, p.name AS project_name, p.worktree,
                               json_extract(m.data, '$.modelID') AS model_id,
                               json_extract(m.data, '$.providerID') AS provider_id,
                               json_extract(m.data, '$.agent') AS agent,
                               COALESCE(json_extract(m.data, '$.tokens.total'), 0) AS tokens_total,
                               COALESCE(json_extract(m.data, '$.tokens.input'), 0) AS tokens_input,
                               COALESCE(json_extract(m.data, '$.tokens.output'), 0) AS tokens_output,
                               COALESCE(json_extract(m.data, '$.tokens.reasoning'), 0) AS tokens_reasoning,
                               COALESCE(json_extract(m.data, '$.tokens.cache.read'), 0) AS cache_read,
                               COALESCE(json_extract(m.data, '$.tokens.cache.write'), 0) AS cache_write,
                               COALESCE(json_extract(m.data, '$.cost'), 0.0) AS cost,
                               NULL AS last_prompt
                        FROM message m
                        JOIN session s ON m.session_id = s.id
                        LEFT JOIN project p ON s.project_id = p.id
                        WHERE json_extract(m.data, '$.role') = 'assistant' AND m.time_created > ? AND COALESCE(json_extract(m.data, '$.tokens.total'), 0) > 0
                        ORDER BY m.time_created ASC
                    '''
                rows = c.execute(sql, (since,)).fetchall()
                mx = since
                for r in rows:
                    tc = int(r['time_created'] or 0)
                    cts = int(r['cursor_ts'] or tc)
                    if cts > mx: mx = cts
                    o_events.append({
                        'dbPath': p,
                        'messageId': r['message_id'],
                        'sessionId': r['session_id'],
                        'timeCreated': tc,
                        'title': r['title'],
                        'directory': r['directory'],
                        'projectName': r['project_name'],
                        'worktree': r['worktree'],
                        'modelId': r['model_id'],
                        'providerId': r['provider_id'],
                        'agent': r['agent'],
                        'tokensTotal': int(r['tokens_total'] or 0),
                        'tokensInput': int(r['tokens_input'] or 0),
                        'tokensOutput': int(r['tokens_output'] or 0),
                        'tokensReasoning': int(r['tokens_reasoning'] or 0),
                        'cacheRead': int(r['cache_read'] or 0),
                        'cacheWrite': int(r['cache_write'] or 0),
                        'cost': float(r['cost'] or 0.0),
                        'lastPrompt': r['last_prompt']
                    })
                if mx > since: o_cur[p] = mx
                c.close()
            except Exception:
                pass
        json.dump({'hermesEvents': h_events, 'hermesCursors': h_cur, 'opencodeEvents': o_events, 'opencodeCursors': o_cur}, sys.stdout)
        """
    }
}
