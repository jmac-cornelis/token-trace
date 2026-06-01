import Foundation
import GRDB

/// A single token usage event from any source
struct UsageEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var observedAt: Date
    var source: Source
    var sessionID: String?
    var sessionTitle: String?
    var requestID: String?
    var projectName: String?
    var repoPath: String?
    var provider: String?
    var model: String?
    var agent: String?
    var promptTokens: Int
    var completionTokens: Int
    var cachedReadTokens: Int
    var cachedWriteTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var estimatedCostUSD: Double
    var lastPrompt: String?

    enum Source: String, Codable, DatabaseValueConvertible {
        case opencode
        case roo
        case codex
        case openclaw
        // `continue` is a Swift reserved keyword; backticks are required at the
        // declaration site. The raw value persisted to the DB is still "continue".
        case `continue`
    }

    static let databaseTableName = "usage_events"
}
