import Foundation
import Combine

@MainActor
final class CollectorService: ObservableObject {
    private let db: DatabaseManager
    private let openCodeReader: OpenCodeReader
    private let rooCodeReader: RooCodeReader
    private let codexReader: CodexReader
    private let openclawReader: OpenclawReader
    private let usageStore: UsageStore
    private var timer: Timer?
    private var isRunning = false

    @Published var isPaused: Bool = false
    @Published var lastCollectTime: Date?
    @Published var collectError: String?

    var pollInterval: TimeInterval = 5.0

    private var settingsCancellable: AnyCancellable?

    init(db: DatabaseManager = .shared, usageStore: UsageStore) {
        self.db = db
        self.openCodeReader = OpenCodeReader()
        self.rooCodeReader = RooCodeReader()
        self.codexReader = CodexReader()
        self.openclawReader = OpenclawReader()
        self.usageStore = usageStore

        settingsCancellable = SettingsManager.shared.$dataSourceMode
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.usageStore.refresh()
                }
            }
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

        let mode = SettingsManager.shared.dataSourceMode
        if mode == .local {
            await collectFromOpenCode()
            await collectFromRooCode()
            await collectFromCodex()
            await collectFromOpenclaw()
            usageStore.refresh()
        } else if mode == .grafana {
            usageStore.refresh()
        }
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

    private func collectFromCodex() async {
        do {
            try codexReader.connect()
            let cursor = try db.getCursor(for: .codex)
            let (events, newCursor) = codexReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try db.setCursor(for: .codex, cursor: newCursor)
            }
            usageStore.codexHealth = codexReader.healthCheck()
        } catch {
            usageStore.codexHealth = SourceHealth(
                source: .codex,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
        }
    }

    private func collectFromOpenclaw() async {
        do {
            let cursor = try db.getCursor(for: .openclaw)
            let (events, newCursor) = openclawReader.fetchEvents(since: cursor)
            if !events.isEmpty {
                try db.insertEvents(events)
            }
            if let newCursor = newCursor {
                try db.setCursor(for: .openclaw, cursor: newCursor)
            }
            usageStore.openclawHealth = openclawReader.healthCheck()
        } catch {
            usageStore.openclawHealth = SourceHealth(
                source: .openclaw,
                isHealthy: false,
                lastEventTime: nil,
                errorMessage: error.localizedDescription,
                eventCount: 0
            )
        }
    }
}
