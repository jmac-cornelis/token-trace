import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    private let db: DatabaseManager

    // MARK: – Today's Token Counts

    @Published var todayTotalTokens: Int = 0
    @Published var todayPromptTokens: Int = 0
    @Published var todayCompletionTokens: Int = 0
    @Published var todayCachedTokens: Int = 0
    @Published var todayReasoningTokens: Int = 0

    // MARK: – Per-Source Breakdowns

    @Published var openCodeTokens: Int = 0
    @Published var rooCodeTokens: Int = 0

    // MARK: – Sessions & Metadata

    @Published var recentSessions: [SessionSummary] = []
    @Published var lastRefreshTime: Date = Date()

    // MARK: – Source Health

    @Published var openCodeHealth: SourceHealth?
    @Published var rooCodeHealth: SourceHealth?

    var openCodeHealthy: Bool { openCodeHealth?.isHealthy ?? false }
    var rooCodeHealthy: Bool { rooCodeHealth?.isHealthy ?? false }

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: – Refresh

    func refresh() {
        do {
            let summary = try db.todaySummary()
            todayTotalTokens = summary.total
            todayPromptTokens = summary.prompt
            todayCompletionTokens = summary.completion
            todayCachedTokens = summary.cached
            todayReasoningTokens = summary.reasoning
            openCodeTokens = summary.bySource[.opencode] ?? 0
            rooCodeTokens = summary.bySource[.roo] ?? 0
            recentSessions = try db.recentSessions(limit: 10)
            lastRefreshTime = Date()
        } catch {
            print("[UsageStore] Refresh error: \(error)")
        }
    }

    // MARK: – Formatting

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    static func formatRelativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
