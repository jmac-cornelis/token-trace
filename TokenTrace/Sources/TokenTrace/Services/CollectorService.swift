import Foundation
import Combine

@MainActor
final class CollectorService: ObservableObject {
    private let db: DatabaseManager
    private let openCodeReader: OpenCodeReader
    private let rooCodeReader: RooCodeReader
    private let usageStore: UsageStore
    private var timer: Timer?
    private var isRunning = false

    @Published var isPaused: Bool = false
    @Published var lastCollectTime: Date?
    @Published var collectError: String?

    var pollInterval: TimeInterval = 5.0

    init(db: DatabaseManager = .shared, usageStore: UsageStore) {
        self.db = db
        self.openCodeReader = OpenCodeReader()
        self.rooCodeReader = RooCodeReader()
        self.usageStore = usageStore
    }

    // MARK: – Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await collect() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.collect()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func togglePause() {
        isPaused.toggle()
    }

    // MARK: – Collection

    private func collect() async {
        guard !isPaused else { return }
        collectError = nil
        await collectFromOpenCode()
        await collectFromRooCode()
        usageStore.refresh()
        lastCollectTime = Date()
    }

    private func collectFromOpenCode() async {
        do {
            try openCodeReader.connect()
            let cursor = try db.getCursor(for: .opencode)
            let (events, newCursor) = openCodeReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try db.setCursor(for: .opencode, cursor: newCursor)
            }
            usageStore.openCodeHealth = openCodeReader.healthCheck()
        } catch {
            usageStore.openCodeHealth = SourceHealth(
                source: .opencode,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
        }
    }

    private func collectFromRooCode() async {
        do {
            let cursor = try db.getCursor(for: .roo)
            let (events, newCursor) = rooCodeReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try db.setCursor(for: .roo, cursor: newCursor)
            }
            usageStore.rooCodeHealth = rooCodeReader.healthCheck()
        } catch {
            usageStore.rooCodeHealth = SourceHealth(
                source: .roo,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
        }
    }
}
