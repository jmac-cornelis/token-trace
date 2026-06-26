import Foundation

final class OpenclawReader {

    private let sessionsBasePath: String

    static let defaultSessionsBasePath: String = "/tmp/agents"

    init(sessionsBasePath: String = OpenclawReader.defaultSessionsBasePath) {
        self.sessionsBasePath = sessionsBasePath
    }

    private struct TranscriptEntry: Codable {
        let message: Message?
        let timestamp: String?
        let provider: String?
        let model: String?

        struct Message: Codable {
            let role: String?
            let provider: String?
            let model: String?
            let usage: Usage?
            let durationMs: Int?
            let timestamp: Int64?

            struct Usage: Codable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation_input_tokens: Int?
                let total_tokens: Int?
                let cost: Cost?

                struct Cost: Codable {
                    let total: Double?
                    let input: Double?
                    let output: Double?
                }
            }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private struct CursorState: Codable {
        var processedFiles: [String: Int64]
    }

    func fetchEvents(since cursor: String?) -> (events: [UsageEvent], newCursor: String?) {
        let cursorState = parseCursor(cursor)
        var newCursorState = cursorState
        var allEvents: [UsageEvent] = []

        let agentsDir = URL(fileURLWithPath: sessionsBasePath)
        guard let agentDirs = try? FileManager.default.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: nil
        ) else {
            return ([], cursor)
        }

        for agentDir in agentDirs {
            let sessionsDir = agentDir.appendingPathComponent("sessions")
            guard let sessionFiles = try? FileManager.default.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else {
                continue
            }

            let jsonlFiles = sessionFiles.filter { $0.pathExtension == "jsonl" }
            let agentId = agentDir.lastPathComponent

            for file in jsonlFiles {
                let filePath = file.path
                let fileKey = "\(agentId)/\(file.lastPathComponent)"

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                      let fileSize = attrs[.size] as? Int64 else {
                    continue
                }

                let previousSize = cursorState.processedFiles[fileKey] ?? 0
                guard fileSize > previousSize else { continue }

                let events = parseTranscriptFile(
                    at: filePath,
                    fromOffset: previousSize,
                    sessionID: file.deletingPathExtension().lastPathComponent,
                    agentId: agentId
                )
                allEvents.append(contentsOf: events)
                newCursorState.processedFiles[fileKey] = fileSize
            }
        }

        let newCursor = encodeCursor(newCursorState)
        return (allEvents, newCursor)
    }

    private func parseTranscriptFile(
        at path: String,
        fromOffset offset: Int64,
        sessionID: String,
        agentId: String
    ) -> [UsageEvent] {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { fileHandle.closeFile() }

        fileHandle.seek(toFileOffset: UInt64(offset))
        guard let data = try? fileHandle.availableData, !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [UsageEvent] = []
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(TranscriptEntry.self, from: lineData),
                  let message = entry.message,
                  message.role == "assistant",
                  let usage = message.usage,
                  let totalTokens = usage.total_tokens,
                  totalTokens > 0 else {
                continue
            }

            let timestamp: Date
            if let epochMs = message.timestamp {
                timestamp = Date(timeIntervalSince1970: Double(epochMs) / 1000.0)
            } else if let isoString = entry.timestamp {
                timestamp = Self.isoFormatter.date(from: isoString) ?? Date()
            } else {
                timestamp = Date()
            }

            let event = UsageEvent(
                id: "\(sessionID)-\(offset)-\(index)",
                observedAt: timestamp,
                source: .openclaw,
                sessionID: sessionID,
                sessionTitle: nil,
                requestID: "\(sessionID)-\(offset)-\(index)",
                projectName: agentId,
                repoPath: nil,
                provider: message.provider ?? entry.provider,
                model: message.model ?? entry.model,
                agent: agentId,
                promptTokens: usage.input_tokens ?? 0,
                completionTokens: usage.output_tokens ?? 0,
                cachedReadTokens: usage.cache_read_input_tokens ?? 0,
                cachedWriteTokens: usage.cache_creation_input_tokens ?? 0,
                reasoningTokens: 0,
                totalTokens: totalTokens,
                estimatedCostUSD: usage.cost?.total ?? 0
            )
            events.append(event)
        }

        return events
    }

    func healthCheck() -> SourceHealth {
        let agentsDir = URL(fileURLWithPath: sessionsBasePath)
        guard FileManager.default.fileExists(atPath: sessionsBasePath) else {
            return SourceHealth(
                source: .openclaw, isHealthy: false, lastEventTime: nil,
                errorMessage: "Sessions directory not found at \(sessionsBasePath)", eventCount: 0
            )
        }

        guard let agentDirs = try? FileManager.default.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: nil
        ) else {
            return SourceHealth(
                source: .openclaw, isHealthy: false, lastEventTime: nil,
                errorMessage: "Cannot read sessions directory", eventCount: 0
            )
        }

        var totalFiles = 0
        var latestModDate: Date?

        for agentDir in agentDirs {
            let sessionsDir = agentDir.appendingPathComponent("sessions")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }
            totalFiles += jsonlFiles.count

            for file in jsonlFiles {
                if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = values.contentModificationDate {
                    if latestModDate == nil || modDate > latestModDate! {
                        latestModDate = modDate
                    }
                }
            }
        }

        return SourceHealth(
            source: .openclaw,
            isHealthy: totalFiles > 0,
            lastEventTime: latestModDate,
            errorMessage: totalFiles == 0 ? "No session transcripts found" : nil,
            eventCount: totalFiles
        )
    }

    private func parseCursor(_ cursor: String?) -> CursorState {
        guard let cursor = cursor,
              let data = cursor.data(using: .utf8),
              let state = try? JSONDecoder().decode(CursorState.self, from: data) else {
            return CursorState(processedFiles: [:])
        }
        return state
    }

    private func encodeCursor(_ state: CursorState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
