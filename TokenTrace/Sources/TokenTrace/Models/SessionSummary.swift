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

    enum ActivityStatus {
        case active
        case idle
        case stale

        var color: String {
            switch self {
            case .active: return "green"
            case .idle: return "yellow"
            case .stale: return "gray"
            }
        }
    }

    var activityStatus: ActivityStatus {
        let elapsed = -lastSeen.timeIntervalSinceNow
        if elapsed < 30 { return .active }
        if elapsed < 300 { return .idle }
        return .stale
    }

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
