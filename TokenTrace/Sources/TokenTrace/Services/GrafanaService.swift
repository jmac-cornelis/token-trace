import Foundation

// MARK: - Error Types

/// Errors that can occur when communicating with the Grafana API.
enum GrafanaError: LocalizedError {
    case networkError(String)
    case parseError(String)
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Grafana network error: \(message)"
        case .parseError(let message):
            return "Grafana parse error: \(message)"
        case .invalidResponse(let statusCode):
            return "Grafana returned HTTP \(statusCode)"
        }
    }
}

// MARK: - Data Models

/// Aggregated token usage for a single calendar day, as reported by Grafana Loki logs.
struct GrafanaDailySummary: Identifiable {
    let date: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int

    var id: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Top-level token usage data aggregated from Grafana Loki log queries.
/// Contains per-day breakdowns and overall totals.
struct GrafanaTokenData {
    let dailySummaries: [GrafanaDailySummary]
    let totalPromptTokens: Int
    let totalCompletionTokens: Int
    let totalTokens: Int
    let totalRequests: Int
}

/// A single model's request count from the PostgreSQL completion table.
struct GrafanaModelBreakdown: Identifiable {
    let model: String
    let requestCount: Int

    var id: String { model }
}

// MARK: - Codable Request Types (avoids JSONSerialization forward-slash escaping)

private struct DatasourceRef: Encodable {
    let uid: String
    let type: String
}

private struct LokiQuery: Encodable {
    let datasource: DatasourceRef
    let expr: String
    let refId: String
    let maxLines: Int
}

private struct PostgresQuery: Encodable {
    let datasource: DatasourceRef
    let rawSql: String
    let refId: String
    let format: String
}

private struct QueryWrapper<Q: Encodable>: Encodable {
    let queries: [Q]
    let from: String
    let to: String
}

// MARK: - GrafanaService

/// Queries the Grafana API (Loki + PostgreSQL datasources) for server-side token usage data.
///
/// This service communicates with Grafana's unified `/api/ds/query` endpoint, which proxies
/// queries to the underlying datasources. Loki provides streaming log data with per-request
/// token counts; PostgreSQL provides per-model request breakdowns.
///
/// The Grafana instance at cn-ai-01 runs with anonymous admin access, so no authentication
/// headers are required.
final class GrafanaService {

    // MARK: - Configuration

    /// Base URL for the Grafana instance. Configurable for testing or alternate deployments.
    let baseURL: String

    /// Loki datasource UID registered in Grafana.
    private let lokiDatasourceUID = "bf8bakei43g1se"

    /// PostgreSQL datasource UID registered in Grafana.
    private let postgresDatasourceUID = "bf8baqg2dpvcwa"

    /// URLSession used for all HTTP requests. Injected for testability.
    private let session: URLSession

    // MARK: - Initialization

    /// Creates a new GrafanaService.
    /// - Parameters:
    ///   - baseURL: Grafana instance URL. Defaults to the cn-ai-01 internal server.
    ///   - session: URLSession to use for requests. Defaults to `.shared`.
    init(
        baseURL: String = "http://cn-ai-01.cornelisnetworks.com:4000",
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Fetches token usage from Grafana Loki logs, grouped by day.
    ///
    /// Loki has a ~30s internal query timeout, so large time ranges (>8h) are split into
    /// parallel 8-hour chunks to avoid server-side timeouts. Each chunk is queried
    /// concurrently via a TaskGroup, and results are merged before aggregation.
    ///
    /// - Parameters:
    ///   - email: User email to filter logs (e.g. "john.macdonald@cornelisnetworks.com").
    ///   - from: Start of time range in Grafana relative format (e.g. "now-7d") or epoch ms.
    ///   - to: End of time range in Grafana relative format (e.g. "now") or epoch ms.
    /// - Returns: Aggregated token data with daily breakdowns and totals.
    /// - Throws: `GrafanaError` on network, parsing, or response errors.
    func fetchTokenUsage(email: String, from: String, to: String) async throws -> GrafanaTokenData {
        let lokiExpr = #"{service_name=~"/python-api_svc.*"} |= "STREAMING RESPONSE TOKENS" |= "user=\#(email)""#

        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let startMs = resolveGrafanaTime(from, relativeTo: nowMs)
        let endMs = resolveGrafanaTime(to, relativeTo: nowMs)

        let totalSpanHours = Int((endMs - startMs) / (3600 * 1000))
        let chunkHours = adaptiveChunkHours(totalSpanHours: totalSpanHours)
        let chunks = buildTimeChunks(startMs: startMs, endMs: endMs, chunkHours: chunkHours)
        var allParsed: [ParsedTokenEntry] = []

        let maxConcurrent = 6
        try await withThrowingTaskGroup(of: [ParsedTokenEntry].self) { group in
            var index = 0

            while index < min(maxConcurrent, chunks.count) {
                let chunk = chunks[index]
                group.addTask {
                    let body = self.buildLokiQueryBody(
                        expr: lokiExpr,
                        from: String(chunk.startMs),
                        to: String(chunk.endMs)
                    )
                    let data = try await self.postQuery(body: body)
                    let lines = try self.parseLokiResponse(data: data)
                    return self.parseTokenLogLines(lines)
                }
                index += 1
            }

            for try await entries in group {
                allParsed.append(contentsOf: entries)
                if index < chunks.count {
                    let chunk = chunks[index]
                    group.addTask {
                        let body = self.buildLokiQueryBody(
                            expr: lokiExpr,
                            from: String(chunk.startMs),
                            to: String(chunk.endMs)
                        )
                        let data = try await self.postQuery(body: body)
                        let lines = try self.parseLokiResponse(data: data)
                        return self.parseTokenLogLines(lines)
                    }
                    index += 1
                }
            }
        }

        return aggregateByDay(allParsed)
    }

    private func adaptiveChunkHours(totalSpanHours: Int) -> Int {
        switch totalSpanHours {
        case ...24:     return 8
        case ...168:    return 24
        case ...720:    return 72
        case ...8760:   return 168
        default:        return 720
        }
    }

    private struct TimeChunk {
        let startMs: Int64
        let endMs: Int64
    }

    private func buildTimeChunks(startMs: Int64, endMs: Int64, chunkHours: Int) -> [TimeChunk] {
        let chunkMs = Int64(chunkHours) * 3600 * 1000
        var chunks: [TimeChunk] = []
        var cursor = startMs

        while cursor < endMs {
            let chunkEnd = min(cursor + chunkMs, endMs)
            chunks.append(TimeChunk(startMs: cursor, endMs: chunkEnd))
            cursor = chunkEnd
        }

        return chunks
    }

    private func resolveGrafanaTime(_ timeStr: String, relativeTo nowMs: Int64) -> Int64 {
        if timeStr == "now" {
            return nowMs
        }

        if timeStr.hasPrefix("now-") {
            let suffix = String(timeStr.dropFirst(4))
            let unit = suffix.last ?? "d"
            let valueStr = String(suffix.dropLast())
            if let value = Int64(valueStr) {
                let ms: Int64
                switch unit {
                case "d": ms = value * 86400 * 1000
                case "h": ms = value * 3600 * 1000
                case "m": ms = value * 60 * 1000
                case "y": ms = value * 365 * 86400 * 1000
                default: ms = value * 86400 * 1000
                }
                return nowMs - ms
            }
        }

        if let epochMs = Int64(timeStr) {
            return epochMs
        }

        return nowMs
    }

    /// Fetches per-model request counts from the PostgreSQL completion table.
    ///
    /// Queries the `completion` table for rows matching the given user, grouped by model name.
    /// Only rows with `datatype = 'request'` and a non-null model are included.
    ///
    /// - Parameters:
    ///   - email: User email to filter (matches `user_name` column).
    ///   - from: Start of time range in Grafana relative format.
    ///   - to: End of time range in Grafana relative format.
    /// - Returns: Array of model breakdowns sorted by request count descending.
    /// - Throws: `GrafanaError` on network, parsing, or response errors.
    func fetchModelBreakdown(email: String, from: String, to: String) async throws -> [GrafanaModelBreakdown] {
        // SQL query groups completion records by model for the given user.
        // The data column is JSONB; we extract the model field with data->>'model'.
        let rawSql = "SELECT model, COUNT(*) as request_count FROM completion WHERE user_name = '\(email)' AND datatype = 'request' AND model IS NOT NULL GROUP BY model ORDER BY request_count DESC"

        let requestBody = buildPostgresQueryBody(rawSql: rawSql, from: from, to: to)
        let responseData = try await postQuery(body: requestBody)
        return try parsePostgresResponse(data: responseData)
    }

    // MARK: - HTTP Layer

    /// Posts a query to Grafana's unified datasource query endpoint.
    ///
    /// The `/api/ds/query` endpoint accepts a JSON body with `queries`, `from`, and `to` fields.
    /// Grafana routes each query to the appropriate datasource based on the `datasource.uid`.
    private func postQuery(body: Data) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/api/ds/query") else {
            throw GrafanaError.networkError("Invalid base URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrafanaError.networkError(error.localizedDescription)
        }

        // Validate HTTP status code — Grafana returns 200 for successful queries.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrafanaError.networkError("Response is not HTTP")
        }
        guard httpResponse.statusCode == 200 else {
            let bodyPreview = String(data: data.prefix(1000), encoding: .utf8) ?? "<non-utf8>"
            throw GrafanaError.parseError("HTTP \(httpResponse.statusCode): \(bodyPreview)")
        }

        return data
    }

    // MARK: - Request Body Builders

    /// Builds the JSON request body for a Loki log query.
    ///
    /// Grafana's `/api/ds/query` expects:
    /// ```json
    /// {
    ///   "queries": [{ "datasource": {"uid": "...", "type": "loki"}, "expr": "...", "refId": "A" }],
    ///   "from": "now-7d",
    ///   "to": "now"
    /// }
    /// ```
    private func buildLokiQueryBody(expr: String, from: String, to: String) -> Data {
        let query = LokiQuery(
            datasource: DatasourceRef(uid: lokiDatasourceUID, type: "loki"),
            expr: expr,
            refId: "A",
            maxLines: 5000
        )
        let wrapper = QueryWrapper(queries: [query], from: from, to: to)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(wrapper) else {
            return Data("{}".utf8)
        }
        return data
    }

    /// Builds the JSON request body for a PostgreSQL raw SQL query.
    ///
    /// The PostgreSQL datasource expects `rawSql` and `format` fields in addition to
    /// the standard datasource identification.
    private func buildPostgresQueryBody(rawSql: String, from: String, to: String) -> Data {
        let query = PostgresQuery(
            datasource: DatasourceRef(uid: postgresDatasourceUID, type: "grafana-postgresql-datasource"),
            rawSql: rawSql,
            refId: "A",
            format: "table"
        )
        let wrapper = QueryWrapper(queries: [query], from: from, to: to)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(wrapper) else {
            return Data("{}".utf8)
        }
        return data
    }

    // MARK: - Loki Response Parsing

    /// Parses the Grafana Loki datasource response to extract raw log line strings.
    ///
    /// Loki returns results in the `results.A.frames` array. Each frame has a `data.values`
    /// array where the log line content is typically in the second element (index 1) — the
    /// first element contains timestamps. Each values sub-array contains the actual strings.
    ///
    /// Response structure:
    /// ```json
    /// {
    ///   "results": {
    ///     "A": {
    ///       "frames": [{
    ///         "data": {
    ///           "values": [
    ///             ["1710288504113000000", ...],  // nanosecond timestamps
    ///             ["log line 1", "log line 2"]   // log content
    ///           ]
    ///         }
    ///       }]
    ///     }
    ///   }
    /// }
    /// ```
    private func parseLokiResponse(data: Data) throws -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrafanaError.parseError("Response is not valid JSON")
        }

        // Navigate: results -> A -> frames
        guard let results = json["results"] as? [String: Any],
              let refA = results["A"] as? [String: Any],
              let frames = refA["frames"] as? [[String: Any]] else {
            throw GrafanaError.parseError("Unexpected Loki response structure: missing results.A.frames")
        }

        var logLines: [String] = []

        for frame in frames {
            // Each frame has a "data" object with a "values" array.
            guard let frameData = frame["data"] as? [String: Any],
                  let values = frameData["values"] as? [[Any]] else {
                continue
            }

            // Loki frames have 6 value arrays: [labels, timestamps_ms, log_lines, nano_ids, encoded_labels, unique_ids].
            // The log line strings are at index 2.
            // Fall back to scanning for the first String array if the structure changes.
            var lines: [String]?
            if values.count > 2, let candidate = values[2] as? [String] {
                lines = candidate
            } else {
                for arr in values {
                    if let strArr = arr as? [String],
                       let first = strArr.first,
                       first.contains("STREAMING RESPONSE TOKENS") {
                        lines = strArr
                        break
                    }
                }
            }

            guard let foundLines = lines else { continue }
            logLines.append(contentsOf: foundLines)
        }

        return logLines
    }

    // MARK: - Log Line Parsing

    /// A single parsed token entry from one Loki log line.
    private struct ParsedTokenEntry {
        let timestamp: Date
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
    }

    /// Parses an array of raw log lines into structured token entries.
    ///
    /// Expected log line format:
    /// ```
    /// 2026-03-12 20:08:24,113:INFO:api_svc:STREAMING RESPONSE TOKENS: prompt=21483, completion=22762, total=44245 (actual=44245), user=john.macdonald@cornelisnetworks.com
    /// ```
    ///
    /// Uses regex to extract:
    /// - Timestamp: `YYYY-MM-DD HH:MM:SS` (comma-separated milliseconds ignored)
    /// - prompt=N, completion=N, total=N
    private func parseTokenLogLines(_ lines: [String]) -> [ParsedTokenEntry] {
        // Regex captures: (1) timestamp, (2) prompt tokens, (3) completion tokens, (4) total tokens.
        // The timestamp format uses comma for millisecond separator (Python logging convention).
        let pattern = #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+:.*prompt=(\d+),\s*completion=(\d+),\s*total=(\d+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            // Pattern is a compile-time constant; failure here is a programming error.
            return []
        }

        // Date formatter for the timestamp portion of each log line.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone.current

        var entries: [ParsedTokenEntry] = []

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 5 else {
                // Skip lines that don't match the expected format (e.g. partial or malformed).
                continue
            }

            // Extract captured groups as Swift String ranges.
            guard let timestampRange = Range(match.range(at: 1), in: line),
                  let promptRange = Range(match.range(at: 2), in: line),
                  let completionRange = Range(match.range(at: 3), in: line),
                  let totalRange = Range(match.range(at: 4), in: line) else {
                continue
            }

            let timestampStr = String(line[timestampRange])
            guard let date = dateFormatter.date(from: timestampStr) else {
                continue
            }

            // Parse token counts — these are always non-negative integers in the log format.
            guard let prompt = Int(line[promptRange]),
                  let completion = Int(line[completionRange]),
                  let total = Int(line[totalRange]) else {
                continue
            }

            entries.append(ParsedTokenEntry(
                timestamp: date,
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total
            ))
        }

        return entries
    }

    // MARK: - Aggregation

    /// Groups parsed token entries by calendar day and computes per-day and overall totals.
    ///
    /// Days are determined using the current calendar's date components (year, month, day).
    /// Results are sorted by date ascending (oldest first).
    private func aggregateByDay(_ entries: [ParsedTokenEntry]) -> GrafanaTokenData {
        let calendar = Calendar.current

        // Group entries by their calendar day (stripping time components).
        var dayBuckets: [DateComponents: [ParsedTokenEntry]] = [:]
        for entry in entries {
            let components = calendar.dateComponents([.year, .month, .day], from: entry.timestamp)
            dayBuckets[components, default: []].append(entry)
        }

        // Build daily summaries from each bucket.
        var dailySummaries: [GrafanaDailySummary] = []
        var totalPrompt = 0
        var totalCompletion = 0
        var totalTokens = 0
        var totalRequests = 0

        for (components, dayEntries) in dayBuckets {
            guard let dayDate = calendar.date(from: components) else { continue }

            let dayPrompt = dayEntries.reduce(0) { $0 + $1.promptTokens }
            let dayCompletion = dayEntries.reduce(0) { $0 + $1.completionTokens }
            let dayTotal = dayEntries.reduce(0) { $0 + $1.totalTokens }
            let dayCount = dayEntries.count

            dailySummaries.append(GrafanaDailySummary(
                date: dayDate,
                promptTokens: dayPrompt,
                completionTokens: dayCompletion,
                totalTokens: dayTotal,
                requestCount: dayCount
            ))

            totalPrompt += dayPrompt
            totalCompletion += dayCompletion
            totalTokens += dayTotal
            totalRequests += dayCount
        }

        // Sort by date ascending so the caller gets chronological order.
        dailySummaries.sort { $0.date < $1.date }

        return GrafanaTokenData(
            dailySummaries: dailySummaries,
            totalPromptTokens: totalPrompt,
            totalCompletionTokens: totalCompletion,
            totalTokens: totalTokens,
            totalRequests: totalRequests
        )
    }

    // MARK: - PostgreSQL Response Parsing

    /// Parses the Grafana PostgreSQL datasource response into model breakdown entries.
    ///
    /// PostgreSQL table-format responses use a "fields" array where each field has a "name"
    /// and "values" array. We locate the "model" and "request_count" fields by name and
    /// zip their values together.
    ///
    /// Response structure:
    /// ```json
    /// {
    ///   "results": {
    ///     "A": {
    ///       "frames": [{
    ///         "data": {
    ///           "values": [["model-a", "model-b"], [150, 42]]
    ///         },
    ///         "schema": {
    ///           "fields": [
    ///             {"name": "model", "type": "string"},
    ///             {"name": "request_count", "type": "number"}
    ///           ]
    ///         }
    ///       }]
    ///     }
    ///   }
    /// }
    /// ```
    private func parsePostgresResponse(data: Data) throws -> [GrafanaModelBreakdown] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrafanaError.parseError("Response is not valid JSON")
        }

        guard let results = json["results"] as? [String: Any],
              let refA = results["A"] as? [String: Any],
              let frames = refA["frames"] as? [[String: Any]] else {
            throw GrafanaError.parseError("Unexpected PostgreSQL response structure: missing results.A.frames")
        }

        var breakdowns: [GrafanaModelBreakdown] = []

        for frame in frames {
            // Extract the schema to find column indices by name.
            guard let schema = frame["schema"] as? [String: Any],
                  let fields = schema["fields"] as? [[String: Any]],
                  let frameData = frame["data"] as? [String: Any],
                  let values = frameData["values"] as? [[Any]] else {
                continue
            }

            // Find the column indices for "model" and "request_count" by scanning field names.
            var modelIndex: Int?
            var countIndex: Int?
            for (i, field) in fields.enumerated() {
                guard let name = field["name"] as? String else { continue }
                if name == "model" { modelIndex = i }
                if name == "request_count" { countIndex = i }
            }

            guard let mIdx = modelIndex, let cIdx = countIndex,
                  mIdx < values.count, cIdx < values.count else {
                continue
            }

            guard let models = values[mIdx] as? [String] else { continue }
            let counts = values[cIdx]

            // Zip model names with their request counts.
            for (i, model) in models.enumerated() where i < counts.count {
                // Grafana may return counts as Int or Double depending on the datasource.
                let count: Int
                if let intVal = counts[i] as? Int {
                    count = intVal
                } else if let doubleVal = counts[i] as? Double {
                    count = Int(doubleVal)
                } else if let numVal = counts[i] as? NSNumber {
                    count = numVal.intValue
                } else {
                    continue
                }

                breakdowns.append(GrafanaModelBreakdown(
                    model: model,
                    requestCount: count
                ))
            }
        }

        // Maintain the ORDER BY request_count DESC from the SQL query.
        return breakdowns
    }
}
