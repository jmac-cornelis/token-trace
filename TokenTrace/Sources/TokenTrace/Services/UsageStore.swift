import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.tokentracker.TokenTrace", category: "UsageStore")

@MainActor
final class UsageStore: ObservableObject {
    private let db: DatabaseManager
    private let settings = SettingsManager.shared
    private var grafanaTask: Task<Void, Never>?

    // MARK: – Today's Token Counts

    @Published var todayTotalTokens: Int = 0
    @Published var todayPromptTokens: Int = 0
    @Published var todayCompletionTokens: Int = 0
    @Published var todayCachedTokens: Int = 0
    @Published var todayReasoningTokens: Int = 0
    @Published var todayCachedReadTokens: Int = 0
    @Published var todayCachedWriteTokens: Int = 0
    @Published var todayBillableTokens: BillableTokens?
    @Published var todayEstimatedCost: Double = 0

    // MARK: – Per-Source Breakdowns

    @Published var openCodeTokens: Int = 0
    @Published var rooCodeTokens: Int = 0
    @Published var codexTokens: Int = 0
    @Published var openclawTokens: Int = 0

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
    @Published var rangeBillableTokens: BillableTokens?
    @Published var rangeEstimatedCost: Double = 0

    // MARK: – Source Health

    @Published var openCodeHealth: SourceHealth?
    @Published var rooCodeHealth: SourceHealth?
    @Published var codexHealth: SourceHealth?
    @Published var openclawHealth: SourceHealth?

    var openCodeHealthy: Bool { openCodeHealth?.isHealthy ?? false }
    var rooCodeHealthy: Bool { rooCodeHealth?.isHealthy ?? false }
    var codexHealthy: Bool { codexHealth?.isHealthy ?? false }
    var openclawHealthy: Bool { openclawHealth?.isHealthy ?? false }

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
        let mode = settings.dataSourceMode
        logger.info("refresh() mode=\(mode.rawValue) email=\(self.settings.grafanaUserEmail) configured=\(self.settings.isGrafanaConfigured)")
        switch mode {
        case .local:
            grafanaTask?.cancel()
            grafanaTask = nil
            isLoadingGrafana = false
            refreshFromLocal()
        case .grafana:
            refreshFromGrafana()
        }
    }

    // MARK: – Local Refresh

    private func refreshFromLocal() {
        dataSourceLabel = "Client-Side"
        grafanaError = nil

        do {
            let summary = try db.todaySummary()
            todayTotalTokens = summary.total
            todayPromptTokens = summary.prompt
            todayCompletionTokens = summary.completion
            todayCachedTokens = summary.cached
            todayReasoningTokens = summary.reasoning
            todayCachedReadTokens = summary.cachedRead
            todayCachedWriteTokens = summary.cachedWrite
            todayEstimatedCost = summary.estimatedCost
            todayBillableTokens = CostEstimator.computeBillableTokens(
                promptTokens: summary.prompt,
                completionTokens: summary.completion,
                cachedReadTokens: summary.cachedRead,
                cachedWriteTokens: summary.cachedWrite,
                reasoningTokens: summary.reasoning
            )
            openCodeTokens = summary.bySource[.opencode] ?? 0
            rooCodeTokens = summary.bySource[.roo] ?? 0
            codexTokens = summary.bySource[.codex] ?? 0
            openclawTokens = summary.bySource[.openclaw] ?? 0
            recentSessions = try db.recentSessions(limit: 10)
            dailySummaries = try db.dailySummaries(days: 14)
            loadChartData()
            lastRefreshTime = Date()

            if settings.showCostEstimates {
                costEstimate = computeLocalCostEstimate()
            } else {
                costEstimate = nil
            }
        } catch {
            logger.error("Refresh error: \(error)")
        }
    }

    // MARK: – Grafana Refresh

    private func refreshFromGrafana(forceFullFetch: Bool = false) {
        guard settings.isGrafanaConfigured else {
            grafanaError = "Grafana user email not configured"
            dataSourceLabel = "Server-Side (Grafana)"
            return
        }

        if isLoadingGrafana {
            return
        }

        let hasCache = cachedGrafanaRange == chartRange && !cachedHistoricalDays.isEmpty
        let isIncremental = hasCache && !forceFullFetch

        if !isIncremental {
            if let last = lastGrafanaFetch, Date().timeIntervalSince(last) < 30, !forceFullFetch {
                return
            }
        }

        isLoadingGrafana = true
        grafanaError = nil
        dataSourceLabel = "Server-Side (Grafana)"

        if !isIncremental {
            todayTotalTokens = 0
            todayPromptTokens = 0
            todayCompletionTokens = 0
            todayCachedTokens = 0
            todayReasoningTokens = 0
            openCodeTokens = 0
            rooCodeTokens = 0
            codexTokens = 0
            openclawTokens = 0
            rangeTotalTokens = 0
            rangePromptTokens = 0
            rangeCompletionTokens = 0
            chartData = []
            dailySummaries = []
            recentSessions = []
            costEstimate = nil
        }

        let email = settings.grafanaUserEmail
        let baseURL = settings.grafanaBaseURL

        grafanaTask?.cancel()
        grafanaTask = Task {
            do {
                let service = GrafanaService(baseURL: baseURL)

                if isIncremental {
                    logger.info("Grafana incremental: fetching today only for \(email, privacy: .public)")
                    let todayData = try await service.fetchTokenUsage(email: email, from: "now/d", to: "now")

                    if Task.isCancelled { return }

                    let todaySummaries = todayData.dailySummaries
                    let merged = self.cachedHistoricalDays.filter { !Calendar.current.isDateInToday($0.date) } + todaySummaries
                    let mergedTokenData = GrafanaTokenData(
                        dailySummaries: merged.sorted { $0.date < $1.date },
                        totalPromptTokens: merged.reduce(0) { $0 + $1.promptTokens },
                        totalCompletionTokens: merged.reduce(0) { $0 + $1.completionTokens },
                        totalTokens: merged.reduce(0) { $0 + $1.totalTokens },
                        totalRequests: merged.reduce(0) { $0 + $1.requestCount }
                    )

                    self.cachedHistoricalDays = mergedTokenData.dailySummaries
                    self.lastGrafanaFetch = Date()
                    applyGrafanaData(tokenData: mergedTokenData, modelBreakdown: self.cachedModelBreakdown ?? [])
                } else {
                    let (from, to) = self.grafanaTimeRange(for: self.chartRange)
                    logger.info("Grafana full fetch: email=\(email, privacy: .public) range=\(from, privacy: .public)..\(to, privacy: .public)")

                    async let tokenDataFuture = service.fetchTokenUsage(email: email, from: from, to: to)
                    async let modelBreakdownFuture = service.fetchModelBreakdown(email: email, from: from, to: to)

                    let tokenData = try await tokenDataFuture
                    let modelBreakdown = try await modelBreakdownFuture

                    if Task.isCancelled { return }

                    logger.info("Grafana OK: \(tokenData.totalTokens, privacy: .public) tokens, \(tokenData.dailySummaries.count, privacy: .public) days, \(modelBreakdown.count, privacy: .public) models")

                    self.cachedGrafanaRange = self.chartRange
                    self.cachedHistoricalDays = tokenData.dailySummaries
                    self.cachedModelBreakdown = modelBreakdown
                    self.lastGrafanaFetch = Date()
                    applyGrafanaData(tokenData: tokenData, modelBreakdown: modelBreakdown)
                }
            } catch is CancellationError {
                logger.info("Grafana fetch cancelled")
            } catch {
                let msg = String(describing: error)
                logger.error("Grafana error: \(msg, privacy: .public)")
                grafanaError = msg
                isLoadingGrafana = false
            }
        }
    }

    private func applyGrafanaData(tokenData: GrafanaTokenData, modelBreakdown: [GrafanaModelBreakdown]) {
        guard settings.dataSourceMode == .grafana else { return }

        let todaySummary = tokenData.dailySummaries.first { Calendar.current.isDateInToday($0.date) }
        todayTotalTokens = todaySummary?.totalTokens ?? 0
        todayPromptTokens = todaySummary?.promptTokens ?? 0
        todayCompletionTokens = todaySummary?.completionTokens ?? 0
        todayCachedTokens = 0
        todayReasoningTokens = 0
        todayCachedReadTokens = 0
        todayCachedWriteTokens = 0
        todayBillableTokens = CostEstimator.computeBillableTokens(
            promptTokens: todaySummary?.promptTokens ?? 0,
            completionTokens: todaySummary?.completionTokens ?? 0,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0
        )
        todayEstimatedCost = 0

        openCodeTokens = tokenData.totalTokens
        rooCodeTokens = 0
        codexTokens = 0
        openclawTokens = 0

        dailySummaries = tokenData.dailySummaries.map { day in
            DailySummary(
                date: day.date,
                totalTokens: day.totalTokens,
                promptTokens: day.promptTokens,
                completionTokens: day.completionTokens,
                cachedTokens: 0,
                reasoningTokens: 0,
                sessionCount: day.requestCount,
                cachedReadTokens: 0,
                cachedWriteTokens: 0,
                estimatedCostUSD: 0
            )
        }

        rangeTotalTokens = tokenData.totalTokens
        rangePromptTokens = tokenData.totalPromptTokens
        rangeCompletionTokens = tokenData.totalCompletionTokens
        rangeBillableTokens = CostEstimator.computeBillableTokens(
            promptTokens: tokenData.totalPromptTokens,
            completionTokens: tokenData.totalCompletionTokens,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0
        )
        rangeEstimatedCost = 0

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        chartData = tokenData.dailySummaries.map { day in
            ChartDataPoint(
                date: day.date,
                totalTokens: day.totalTokens,
                promptTokens: day.promptTokens,
                completionTokens: day.completionTokens,
                label: fmt.string(from: day.date)
            )
        }

        if settings.showCostEstimates {
            let todayGrafana = tokenData.dailySummaries.first { Calendar.current.isDateInToday($0.date) }
            let modelCounts = modelBreakdown.map { (model: $0.model, count: $0.requestCount) }
            costEstimate = CostEstimator.estimate(
                totalPromptTokens: todayGrafana?.promptTokens ?? 0,
                totalCompletionTokens: todayGrafana?.completionTokens ?? 0,
                modelRequestCounts: modelCounts
            )
        } else {
            costEstimate = nil
        }

        recentSessions = []
        lastRefreshTime = Date()
        isLoadingGrafana = false
    }

    // MARK: – Local Cost Estimation

    private func computeLocalCostEstimate() -> CostEstimate {
        var modelCounts: [String: Int] = [:]
        for session in recentSessions {
            let model = session.model ?? "unknown"
            modelCounts[model, default: 0] += session.eventCount
        }
        return CostEstimator.estimate(
            totalPromptTokens: todayPromptTokens,
            totalCompletionTokens: todayCompletionTokens,
            modelRequestCounts: modelCounts.map { (model: $0.key, count: $0.value) }
        )
    }

    // MARK: – Grafana Time Range

    private func grafanaTimeRange(for range: ChartRange) -> (String, String) {
        switch range {
        case .week:  return ("now-7d", "now")
        case .month: return ("now-30d", "now")
        case .year:  return ("now-1y", "now")
        case .total: return ("now-5y", "now")
        }
    }

    // MARK: – Helpers

    static let formatTokens = TokenFormatter.formatTokens
    static let formatRelativeTime = TokenFormatter.formatRelativeTime

    func loadChartData() {
        if settings.dataSourceMode == .grafana { return }
        do {
            chartData = try db.chartData(range: chartRange)
            let summary = try db.rangeSummary(range: chartRange)
            rangeTotalTokens = summary.total
            rangePromptTokens = summary.prompt
            rangeCompletionTokens = summary.completion
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
        if settings.dataSourceMode == .grafana {
            grafanaTask?.cancel()
            isLoadingGrafana = false
            lastGrafanaFetch = nil
            cachedGrafanaRange = nil
            cachedHistoricalDays = []
            cachedModelBreakdown = nil
            refreshFromGrafana(forceFullFetch: true)
        } else {
            loadChartData()
        }
    }

    func loadSessionsForDate(_ date: Date) {
        do {
            selectedDaySessions = try db.sessionsForDate(date)
            selectedDaySourceTotals = try db.sourceTotalsForDate(date)
        } catch {
            logger.error("Failed to load sessions for date: \(error)")
        }
    }
}
