import Foundation
import GRDB

/// A single token usage event from any source
struct UsageEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var observedAt: Date
    var source: Source
    var sessionID: String?
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

    enum Source: String, Codable, DatabaseValueConvertible {
        case opencode
        case roo
    }

    static let databaseTableName = "usage_events"
}
