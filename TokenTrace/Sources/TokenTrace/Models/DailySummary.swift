import Foundation

struct DailySummary: Identifiable, Sendable {
    let date: Date
    let totalTokens: Int
    let promptTokens: Int
    // Per-turn input excluding the re-sent conversation prefix that promptTokens recounts each turn.
    let newInputTokens: Int
    let completionTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let sessionCount: Int
    let cachedReadTokens: Int
    let cachedWriteTokens: Int
    let estimatedCostUSD: Double

    var uniqueWork: Int {
        newInputTokens + completionTokens + reasoningTokens
    }

    var billableTokens: BillableTokens {
        CostEstimator.computeBillableTokens(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedReadTokens: cachedReadTokens,
            cachedWriteTokens: cachedWriteTokens,
            reasoningTokens: reasoningTokens
        )
    }

    var id: String {
        Self.idFormatter.string(from: date)
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var formattedDate: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return Self.displayFormatter.string(from: date)
    }

    // Perf: id is read constantly during SwiftUI diffing; avoid per-access DateFormatter alloc.
    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()
}
