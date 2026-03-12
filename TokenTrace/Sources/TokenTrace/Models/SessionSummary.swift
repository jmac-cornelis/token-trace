import Foundation

struct SessionSummary: Identifiable {
    let id: String
    let source: UsageEvent.Source
    let title: String?
    let projectName: String?
    let model: String?
    let agent: String?
    let totalTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let eventCount: Int
    let firstSeen: Date
    let lastSeen: Date

    var displayName: String {
        if let title = title, !title.isEmpty {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 50 {
                return String(trimmed.prefix(47)) + "..."
            }
            return trimmed
        }
        return projectName ?? id
    }
}
