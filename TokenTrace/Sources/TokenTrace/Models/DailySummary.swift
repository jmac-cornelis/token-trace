import Foundation

struct DailySummary: Identifiable {
    let date: Date
    let totalTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let sessionCount: Int

    var id: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var formattedDate: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}
