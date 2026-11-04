import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.tokentracker.TokenTrace", category: "UsageStore")

@MainActor
final class UsageStore: ObservableObject {
    private let db: DatabaseManager
    private let settings = SettingsManager.shared
    private var grafanaTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?

    // MARK: – Today's Token Counts

    @Published var todayTotalTokens: Int = 0
    @Published var todayPromptTokens: Int = 0
    @Published var todayCompletionTokens: Int = 0
    @Published var todayCachedTokens: Int = 0
    @Published var todayReasoningTokens: Int = 0
    @Published var todayCachedReadTokens: Int = 0
    @Published var todayCachedWriteTokens: Int = 0
    @Published var todayUniqueWork: Int = 0
    @Published var todayBillableTokens: BillableTokens?
    @Published var todayEstimatedCost: Double = 0
    @Published var todayCacheModeledCost: Double = 0

    // MARK: – Per-Source Breakdowns

    @Published var openCodeTokens: Int = 0
    @Published var codexTokens: Int = 0
    @Published var hermesTokens: Int = 0
    @Published var openclawTokens: Int = 0
    @Published var continueTokens: Int = 0

    // MARK: – Sessions & Metadata

    @Published var recentSessions: [SessionSummary] = []
    @Published var dailySummaries: [DailySummary] = []
    @Published var selectedDaySessions: [SessionSummary] = []
    @Published var selectedDaySourceTotals: [UsageEvent.Source: Int] = [:]
    @Published var lastRefreshTime: Date = Date()

    @Published var chartRange: ChartRange = .week
    @Published var chartData: [ChartDataPoint] = []
    @Published var rangeTotalTokens: Int = 0
    @Published var rangePromptTokens: Int = 0
    @Published var rangeCompletionTokens: Int = 0
    @Published var rangeUniqueWork: Int = 0
    @Published var rangeBillableTokens: BillableTokens?
    @Published var rangeEstimatedCost: Double = 0

    // MARK: – Source Health

    @Published var openCodeHealth: SourceHealth?
    @Published var codexHealth: SourceHealth?
    @Published var hermesHealth: SourceHealth?
    @Published var openclawHealth: SourceHealth?
    @Published var continueHealth: SourceHealth?

    var openCodeHealthy: Bool { openCodeHealth?.isHealthy ?? false }
    var codexHealthy: Bool { codexHealth?.isHealthy ?? false }
    var hermesHealthy: Bool { hermesHealth?.isHealthy ?? false }
    var openclawHealthy: Bool { openclawHealth?.isHealthy ?? false }
    var continueHealthy: Bool { continueHealth?.isHealthy ?? false }

    // MARK: – Cost & Grafana State

    @Published var costEstimate: CostEstimate?
    @Published var grafanaError: String?
    @Published var isLoadingGrafana: Bool = false
    @Published var dataSourceLabel: String = "Client-Side"
    private var lastGrafanaFetch: Date?

    private var cachedGrafanaRange: ChartRange?
    private var cachedHistoricalDays: [GrafanaDailySummary] = []
    private var cachedModelBreakdown: [GrafanaModelBreakdown]?

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: – Refresh (called by CollectorService every 5s)

    func refresh() {
        localTask?.cancel()
        localTask = Task { await self.refreshFromLocal() }
    }

    // Awaitable refresh: refresh() is fire-and-forget, so tests await this instead.
    func refreshNow() async {
        await refreshFromLocal()
    }

    // MARK: – Local Refresh

    private func refreshFromLocal() async {
        dataSourceLabel = "Client-Side"
        grafanaError = nil

        do {
            let summary = try await db.todaySummary()
            todayTotalTokens = summary.total
            todayPromptTokens = summary.prompt
            todayCompletionTokens = summary.completion
            todayCachedTokens = summary.cached
            todayReasoningTokens = summary.reasoning
            todayCachedReadTokens = summary.cachedRead
            todayCachedWriteTokens = summary.cachedWrite
            todayUniqueWork = summary.newInput + summary.completion + summary.reasoning
            todayEstimatedCost = summary.estimatedCost
            todayCacheModeledCost = CostEstimator.estimateCacheModeledCost(
                promptTokens: summary.prompt,
                newInputTokens: summary.newInput,
                completionTokens: summary.completion,
                cachedReadTokens: summary.cachedRead,
                cachedWriteTokens: summary.cachedWrite,
                reasoningTokens: summary.reasoning,
                model: nil
            )
            todayBillableTokens = CostEstimator.computeBillableTokens(
                promptTokens: summary.prompt,
                completionTokens: summary.completion,
                cachedReadTokens: summary.cachedRead,
                cachedWriteTokens: summary.cachedWrite,
                reasoningTokens: summary.reasoning
            )
            openCodeTokens = summary.bySource[.opencode] ?? 0
            codexTokens = summary.bySource[.codex] ?? 0
            hermesTokens = summary.bySource[.hermes] ?? 0
            openclawTokens = summary.bySource[.openclaw] ?? 0
            continueTokens = summary.bySource[.continue] ?? 0
            recentSessions = try await db.recentSessions(limit: 10)
            dailySummaries = try await db.dailySummaries(days: 14)
            await loadChartDataAsync()
            lastRefreshTime = Date()

            if settings.showCostEstimates {
                costEstimate = try await db.todayModelCostEstimate()
            } else {
                costEstimate = nil
            }
        } catch {
            logger.error("Refresh error: \(error)")
        }
    }

    // MARK: – Helpers

    static let formatTokens = TokenFormatter.formatTokens
    static let formatRelativeTime = TokenFormatter.formatRelativeTime

    func loadChartData() {
        Task { await loadChartDataAsync() }
    }

    private func loadChartDataAsync() async {
        do {
            chartData = try await db.chartData(range: chartRange)
            let summary = try await db.rangeSummary(range: chartRange)
            rangeTotalTokens = summary.total
            rangePromptTokens = summary.prompt
            rangeCompletionTokens = summary.completion
            rangeUniqueWork = summary.newInput + summary.completion + summary.reasoning
            rangeBillableTokens = CostEstimator.computeBillableTokens(
                promptTokens: summary.prompt,
                completionTokens: summary.completion,
                cachedReadTokens: summary.cachedRead,
                cachedWriteTokens: summary.cachedWrite,
                reasoningTokens: summary.reasoning
            )
            rangeEstimatedCost = summary.estimatedCost
        } catch {
            logger.error("Chart data error: \(error)")
        }
    }

    func setChartRange(_ range: ChartRange) {
        chartRange = range
        loadChartData()
    }

    func loadSessionsForDate(_ date: Date) {
        Task {
            do {
                selectedDaySessions = try await db.sessionsForDate(date)
                selectedDaySourceTotals = try await db.sourceTotalsForDate(date)
            } catch {
                logger.error("Failed to load sessions for date: \(error)")
            }
        }
    }
}
