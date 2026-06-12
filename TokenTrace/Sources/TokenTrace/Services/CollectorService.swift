import Foundation
import Combine

@MainActor
final class CollectorService: ObservableObject {
    private let db: DatabaseManager
    private let engine: CollectionEngine
    private let usageStore: UsageStore
    private var timer: Timer?
    private var isRunning = false
    private var isCollecting = false

    @Published var isPaused: Bool = false
    @Published var lastCollectTime: Date?
    @Published var collectError: String?

    var pollInterval: TimeInterval = 5.0

    private var settingsCancellable: AnyCancellable?

    init(db: DatabaseManager = .shared, usageStore: UsageStore) {
        self.db = db
        self.engine = CollectionEngine(db: db)
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
        guard !isPaused, !isCollecting else { return }
        isCollecting = true
        defer { isCollecting = false }
        collectError = nil

        let mode = SettingsManager.shared.dataSourceMode
        if mode == .local {
            let outcome = await engine.collect()
            usageStore.openCodeHealth = outcome.openCodeHealth
            usageStore.codexHealth = outcome.codexHealth
            usageStore.openclawHealth = outcome.openclawHealth
            usageStore.continueHealth = outcome.continueHealth
            if outcome.insertedCount > 0 {
                usageStore.refresh()
            }
        } else if mode == .grafana {
            usageStore.refresh()
        }
        lastCollectTime = Date()
    }
}
