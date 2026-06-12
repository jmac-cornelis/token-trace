import SwiftUI

@main
struct TokenTraceApp: App {
    @StateObject private var usageStore: UsageStore
    @StateObject private var collector: CollectorService

    init() {
        do {
            try DatabaseManager.shared.setup()
        } catch {
            fatalError("Failed to setup database: \(error)")
        }

        CostEstimator.reloadConfiguredPricing()

        let store = UsageStore()
        let collectorService = CollectorService(usageStore: store)

        store.refresh()
        collectorService.start()

        _usageStore = StateObject(wrappedValue: store)
        _collector = StateObject(wrappedValue: collectorService)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown()
                .environmentObject(usageStore)
                .environmentObject(collector)
                .environmentObject(SettingsManager.shared)
        } label: {
            MenuBarIcon(usageStore: usageStore)
        }
        .menuBarExtraStyle(.window)
    }
}
