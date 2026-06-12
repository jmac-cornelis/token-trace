import Foundation

struct SourceHealth: Sendable {
    let source: UsageEvent.Source
    var isHealthy: Bool
    var lastEventTime: Date?
    var errorMessage: String?
    var eventCount: Int
}

enum ReaderError: LocalizedError {
    case databaseNotFound(String)
    case notConnected
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path): return "Database not found at \(path)"
        case .notConnected: return "Reader not connected"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
