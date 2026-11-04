import Foundation
import Combine

@MainActor
final class CollectorService: ObservableObject {
    private let db: DatabaseManager
    private let engine: CollectionEngine
    private let usageStore: UsageStore
    private var timer: Timer?
    private var fileWatcher: FileWatcher?
    private var isRunning = false
    private var isCollecting = false

    @Published var isPaused: Bool = false
    @Published var lastCollectTime: Date?
    @Published var collectError: String?

    // Fallback safety net; FileWatcher drives collection in .local mode.
    var pollInterval: TimeInterval = 60.0

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
        let watcher = FileWatcher { [weak self] in
            Task { @MainActor [weak self] in
                await self?.collect()
            }
        }
        watcher.start()
        fileWatcher = watcher
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fileWatcher?.stop()
        fileWatcher = nil
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

        let outcome = await engine.collect(
            remoteHost: SettingsManager.shared.remoteSSHHost,
            remoteEnabled: SettingsManager.shared.remoteSyncEnabled
        )
        usageStore.openCodeHealth = outcome.openCodeHealth
        usageStore.codexHealth = outcome.codexHealth
        usageStore.hermesHealth = outcome.hermesHealth
        usageStore.openclawHealth = outcome.openclawHealth
        usageStore.continueHealth = outcome.continueHealth
        if outcome.insertedCount > 0 {
            usageStore.refresh()
        }
        lastCollectTime = Date()
    }
}
