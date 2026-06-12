import SwiftUI

struct MenuBarDropdown: View {
    @EnvironmentObject var usageStore: UsageStore
    @EnvironmentObject var collector: CollectorService
    @State private var expandedSessionID: String?
    @State private var expandedDay: String?
    @State private var showCostEstimate: Bool = false
    @State private var showSources: Bool = false
    @State private var showBreakdown: Bool = false
    @State private var showRecentSessions: Bool = false
    @State private var showHistory: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection

            Divider().padding(.horizontal, 12)

            todaySummarySection

            Divider().padding(.horizontal, 12)

            if SettingsManager.shared.showCostEstimates {
                costEstimateSection

                Divider().padding(.horizontal, 12)
            }

            usageChartSection

            Divider().padding(.horizontal, 12)

            sourceBreakdownSection

            Divider().padding(.horizontal, 12)

            tokenBreakdownSection

            Divider().padding(.horizontal, 12)

            recentSessionsSection

            Divider().padding(.horizontal, 12)

            historySection

            Divider().padding(.horizontal, 12)

            settingsSection

            Divider().padding(.horizontal, 12)

            actionsSection
        }
        .frame(width: 320)
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Text("Token Trace")
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            Text("Updated \(UsageStore.formatRelativeTime(usageStore.lastRefreshTime))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var todaySummarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("TODAY")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
                Text(usageStore.dataSourceLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }

            if usageStore.isLoadingGrafana && usageStore.todayTotalTokens == 0 {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching from Grafana…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 34)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageStore.formatTokens(usageStore.todayUniqueWork))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("unique tokens")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .help("Unique work = new input + output + reasoning. Excludes the growing conversation context that is re-sent on every turn.")

                HStack(spacing: 4) {
                    Text("Provider total")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(UsageStore.formatTokens(usageStore.todayTotalTokens))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .help("Total tokens the provider processed, counting re-sent context on every turn. This is the uncached billing basis, not a measure of unique work.")

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("In")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(UsageStore.formatTokens(usageStore.todayPromptTokens))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Out")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(UsageStore.formatTokens(usageStore.todayCompletionTokens))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sourceBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showSources.toggle()
                }
            }) {
                HStack {
                    Text("SOURCES")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showSources ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showSources {
                sourceRow(
                    name: "OpenCode",
                    tokens: usageStore.openCodeTokens,
                    isHealthy: usageStore.openCodeHealthy,
                    icon: "terminal.fill"
                )
                sourceRow(
                    name: "Codex",
                    tokens: usageStore.codexTokens,
                    isHealthy: usageStore.codexHealthy,
                    icon: "sparkle",
                    subscriptionBased: true
                )
                sourceRow(
                    name: "Openclaw",
                    tokens: usageStore.openclawTokens,
                    isHealthy: usageStore.openclawHealthy,
                    icon: "network"
                )
                sourceRow(
                    name: "Continue",
                    tokens: usageStore.continueTokens,
                    isHealthy: usageStore.continueHealthy,
                    icon: "arrow.triangle.branch"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sourceRow(name: String, tokens: Int, isHealthy: Bool, icon: String, subscriptionBased: Bool = false) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isHealthy ? Color.secondary : Color.red)
                .frame(width: 16)
            Text(name)
                .font(.subheadline)
            if subscriptionBased {
                Text("subscription")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Text(UsageStore.formatTokens(tokens))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var costEstimateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showCostEstimate.toggle()
                }
            }) {
                HStack {
                    Text("ESTIMATED COST")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showCostEstimate ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showCostEstimate {
                CostEstimateView()
                    .environmentObject(usageStore)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var usageChartSection: some View {
        UsageChartView()
            .environmentObject(usageStore)
    }

    private var tokenBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showBreakdown.toggle()
                }
            }) {
                HStack {
                    Text("BREAKDOWN")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showBreakdown ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showBreakdown {
                breakdownRow(label: "Unique Work", value: usageStore.todayUniqueWork)
                breakdownRow(label: "Provider Total", value: usageStore.todayTotalTokens)
                breakdownRow(label: "Prompt", value: usageStore.todayPromptTokens)
                breakdownRow(label: "Completion", value: usageStore.todayCompletionTokens)
                breakdownRow(label: "Cached", value: usageStore.todayCachedTokens)
                if usageStore.todayCachedReadTokens > 0 || usageStore.todayCachedWriteTokens > 0 {
                    HStack(spacing: 12) {
                        HStack(spacing: 3) {
                            Text("Read")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(UsageStore.formatTokens(usageStore.todayCachedReadTokens))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 3) {
                            Text("Write")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(UsageStore.formatTokens(usageStore.todayCachedWriteTokens))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 12)
                }
                if usageStore.todayReasoningTokens > 0 {
                    breakdownRow(label: "Reasoning", value: usageStore.todayReasoningTokens)
                }
                if let billable = usageStore.todayBillableTokens {
                    Divider().padding(.vertical, 2)
                    breakdownRow(label: "Billable Input", value: Int(billable.billableInputEquivalent.rounded()))
                    breakdownRow(label: "Billable Total", value: Int(billable.totalBillableEquivalent.rounded()))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func breakdownRow(label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(UsageStore.formatTokens(value))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showRecentSessions.toggle()
                }
            }) {
                HStack {
                    Text("RECENT SESSIONS")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showRecentSessions ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showRecentSessions {
                if usageStore.recentSessions.isEmpty {
                    Text("No sessions yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(usageStore.recentSessions.prefix(5)) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let isExpanded = expandedSessionID == session.id
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedSessionID = isExpanded ? nil : session.id
                }
            }) {
                HStack {
                    SessionStatusDot(status: session.activityStatus)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayName)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let prompt = session.lastPrompt, !prompt.isEmpty {
                            Text(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        HStack(spacing: 4) {
                            if let project = session.projectName {
                                Text(project)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let model = session.model {
                                Text(model)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(UsageStore.formatRelativeTime(session.lastSeen))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Text(UsageStore.formatTokens(session.uniqueWork))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    sessionDetailRow("Unique Work", session.uniqueWork)
                    sessionDetailRow("Provider Total", session.totalTokens)
                    sessionDetailRow("Prompt", session.promptTokens)
                    sessionDetailRow("Completion", session.completionTokens)
                    if session.cachedTokens > 0 {
                        sessionDetailRow("Cached", session.cachedTokens)
                    }
                    if session.reasoningTokens > 0 {
                        sessionDetailRow("Reasoning", session.reasoningTokens)
                    }
                    let sb = session.billableTokens
                    if sb.cacheSavingsPercent > 0 {
                        HStack {
                            Text("Billable")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Spacer()
                            Text(UsageStore.formatTokens(Int(sb.totalBillableEquivalent.rounded())))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                            Text("(\(Int(sb.cacheSavingsPercent))% saved)")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    if session.estimatedCostUSD > 0 {
                        HStack {
                            Text("Cost")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Spacer()
                            Text(CostEstimator.formatCost(session.estimatedCostUSD))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("\(session.eventCount) requests")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        if let agent = session.agent {
                            Text("· \(agent)")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.leading, 18)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sessionDetailRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.quaternary)
            Spacer()
            Text(UsageStore.formatTokens(value))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showHistory.toggle()
                }
            }) {
                HStack {
                    Text("HISTORY")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showHistory ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showHistory {
                let pastDays = usageStore.dailySummaries.filter { !$0.isToday }

                if pastDays.isEmpty {
                    Text("No history yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(pastDays.prefix(7)) { day in
                        dayRow(day)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func dayRow(_ day: DailySummary) -> some View {
        let isExpanded = expandedDay == day.id
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedDay = nil
                    } else {
                        expandedDay = day.id
                        usageStore.loadSessionsForDate(day.date)
                    }
                }
            }) {
                HStack {
                    Text(day.formattedDate)
                        .font(.subheadline)
                    Spacer()
                    Text("\(day.sessionCount)s")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text(UsageStore.formatTokens(day.uniqueWork))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        HStack(spacing: 3) {
                            Text("In")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(UsageStore.formatTokens(day.promptTokens))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 3) {
                            Text("Out")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(UsageStore.formatTokens(day.completionTokens))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        if day.cachedTokens > 0 {
                            HStack(spacing: 3) {
                                Text("Cached")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                                Text(UsageStore.formatTokens(day.cachedTokens))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 4)

                    let db = day.billableTokens
                    if db.cacheSavingsPercent > 0 || day.estimatedCostUSD > 0 {
                        HStack(spacing: 12) {
                            if db.cacheSavingsPercent > 0 {
                                HStack(spacing: 3) {
                                    Text("Billable")
                                        .font(.caption2)
                                        .foregroundStyle(.quaternary)
                                    Text(UsageStore.formatTokens(Int(db.totalBillableEquivalent.rounded())))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.orange)
                                }
                            }
                            if day.estimatedCostUSD > 0 {
                                HStack(spacing: 3) {
                                    Text("≈")
                                        .font(.caption2)
                                        .foregroundStyle(.quaternary)
                                    Text(CostEstimator.formatCost(day.estimatedCostUSD))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    let sourceTotals = usageStore.selectedDaySourceTotals
                    if !sourceTotals.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(sourceTotals.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { source in
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(sourceColor(source))
                                        .frame(width: 4, height: 4)
                                    Text(sourceName(source))
                                        .font(.caption2)
                                        .foregroundStyle(.quaternary)
                                    Text(UsageStore.formatTokens(sourceTotals[source] ?? 0))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if !usageStore.selectedDaySessions.isEmpty {
                        Divider()
                            .padding(.vertical, 2)
                    }

                    ForEach(usageStore.selectedDaySessions) { session in
                        HStack {
                            Circle()
                                .fill(sourceColor(session.source))
                                .frame(width: 5, height: 5)
                            Text(session.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(UsageStore.formatTokens(session.uniqueWork))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sourceColor(_ source: UsageEvent.Source) -> Color {
        switch source {
        case .opencode: return .blue
        case .codex: return .green
        case .openclaw: return .orange
        case .continue: return .pink
        }
    }

    private func sourceName(_ source: UsageEvent.Source) -> String {
        switch source {
        case .opencode: return "OC"
        case .codex: return "Cdx"
        case .openclaw: return "OClw"
        case .continue: return "Cont"
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showSettings.toggle()
                }
            }) {
                HStack {
                    Text("SETTINGS")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showSettings ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showSettings {
                SettingsView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button(action: { collector.togglePause() }) {
                Label(
                    collector.isPaused ? "Resume" : "Pause",
                    systemImage: collector.isPaused ? "play.fill" : "pause.fill"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "xmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
