import Testing
import Foundation
@testable import TokenTrace

@Suite("Formatting & Models")
struct FormatTests {

    @Test func formatTokensUnderThousand() {
        #expect(TokenFormatter.formatTokens(0) == "0")
        #expect(TokenFormatter.formatTokens(1) == "1")
        #expect(TokenFormatter.formatTokens(999) == "999")
    }

    @Test func formatTokensThousands() {
        #expect(TokenFormatter.formatTokens(1000) == "1.0k")
        #expect(TokenFormatter.formatTokens(1500) == "1.5k")
        #expect(TokenFormatter.formatTokens(12400) == "12.4k")
        #expect(TokenFormatter.formatTokens(999999) == "1000.0k")
    }

    @Test func formatTokensMillions() {
        #expect(TokenFormatter.formatTokens(1_000_000) == "1.0M")
        #expect(TokenFormatter.formatTokens(133_200_000) == "133.2M")
        #expect(TokenFormatter.formatTokens(1_500_000) == "1.5M")
    }

    @Test func sessionDisplayNameUsesTitle() {
        let session = SessionSummary(
            id: "ses_123", source: .opencode, title: "Fix auth middleware",
            projectName: "my-project", model: nil, agent: nil,
            totalTokens: 0, promptTokens: 0, completionTokens: 0,
            cachedTokens: 0, reasoningTokens: 0,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0,
            eventCount: 0, firstSeen: Date(), lastSeen: Date(), lastPrompt: nil
        )
        #expect(session.displayName == "Fix auth middleware")
    }

    @Test func sessionDisplayNameTruncatesLongTitle() {
        let longTitle = String(repeating: "a", count: 60)
        let session = SessionSummary(
            id: "ses_123", source: .opencode, title: longTitle,
            projectName: nil, model: nil, agent: nil,
            totalTokens: 0, promptTokens: 0, completionTokens: 0,
            cachedTokens: 0, reasoningTokens: 0,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0,
            eventCount: 0, firstSeen: Date(), lastSeen: Date(), lastPrompt: nil
        )
        #expect(session.displayName.count == 50)
        #expect(session.displayName.hasSuffix("..."))
    }

    @Test func sessionDisplayNameFallsBackToProject() {
        let session = SessionSummary(
            id: "ses_123", source: .opencode, title: nil,
            projectName: "my-project", model: nil, agent: nil,
            totalTokens: 0, promptTokens: 0, completionTokens: 0,
            cachedTokens: 0, reasoningTokens: 0,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0,
            eventCount: 0, firstSeen: Date(), lastSeen: Date(), lastPrompt: nil
        )
        #expect(session.displayName == "my-project")
    }

    @Test func sessionDisplayNameFallsBackToID() {
        let session = SessionSummary(
            id: "ses_123", source: .opencode, title: nil,
            projectName: nil, model: nil, agent: nil,
            totalTokens: 0, promptTokens: 0, completionTokens: 0,
            cachedTokens: 0, reasoningTokens: 0,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0,
            eventCount: 0, firstSeen: Date(), lastSeen: Date(), lastPrompt: nil
        )
        #expect(session.displayName == "ses_123")
    }

    @Test func dailySummaryIsToday() {
        let today = DailySummary(
            date: Date(), totalTokens: 100, promptTokens: 50,
            completionTokens: 50, cachedTokens: 0, reasoningTokens: 0, sessionCount: 1,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0
        )
        #expect(today.isToday)

        let yesterday = DailySummary(
            date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
            totalTokens: 100, promptTokens: 50, completionTokens: 50,
            cachedTokens: 0, reasoningTokens: 0, sessionCount: 1,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0
        )
        #expect(!yesterday.isToday)
    }

    @Test func dailySummaryFormattedDate() {
        let today = DailySummary(
            date: Date(), totalTokens: 0, promptTokens: 0,
            completionTokens: 0, cachedTokens: 0, reasoningTokens: 0, sessionCount: 0,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0
        )
        #expect(today.formattedDate == "Today")

        let yesterday = DailySummary(
            date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
            totalTokens: 0, promptTokens: 0, completionTokens: 0,
            cachedTokens: 0, reasoningTokens: 0, sessionCount: 0,
            cachedReadTokens: 0, cachedWriteTokens: 0, estimatedCostUSD: 0
        )
        #expect(yesterday.formattedDate == "Yesterday")
    }

    @Test func chartRangeDays() {
        #expect(ChartRange.week.days == 7)
        #expect(ChartRange.month.days == 30)
        #expect(ChartRange.year.days == 365)
        #expect(ChartRange.total.days == nil)
    }
}
