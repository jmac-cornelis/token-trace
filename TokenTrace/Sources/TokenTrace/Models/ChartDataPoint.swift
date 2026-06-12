import Foundation

struct ChartDataPoint: Identifiable, Sendable {
    let date: Date
    let totalTokens: Int
    let promptTokens: Int
    // Per-turn input excluding the re-sent conversation prefix that promptTokens recounts each turn.
    let newInputTokens: Int
    let completionTokens: Int
    let label: String

    var id: String { label }

    var uniqueWork: Int {
        newInputTokens + completionTokens
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case week = "7D"
    case month = "30D"
    case year = "1Y"
    case total = "All"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        case .total: return nil
        }
    }
}
