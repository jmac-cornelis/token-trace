import SwiftUI

struct MenuBarDropdown: View {
    @EnvironmentObject var usageStore: UsageStore
    @EnvironmentObject var collector: CollectorService
    @State private var expandedSessionID: String?
    @State private var expandedDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection

            Divider().padding(.horizontal, 12)

            todaySummarySection

            Divider().padding(.horizontal, 12)

            UsageChartView()
                .environmentObject(usageStore)

            Divider().padding(.horizontal, 12)

            sourceBreakdownSection

            Divider().padding(.horizontal, 12)

            tokenBreakdownSection

            Divider().padding(.horizontal, 12)

            recentSessionsSection

            Divider().padding(.horizontal, 12)

            historySection

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
            Text("TODAY")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

            HStack(alignment: .firstTextBaseline) {
                Text(UsageStore.formatTokens(usageStore.todayTotalTokens))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sourceBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCES")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

            sourceRow(
                name: "OpenCode",
                tokens: usageStore.openCodeTokens,
                isHealthy: usageStore.openCodeHealthy,
                icon: "terminal.fill"
            )
            sourceRow(
                name: "Roo Code",
                tokens: usageStore.rooCodeTokens,
                isHealthy: usageStore.rooCodeHealthy,
                icon: "hammer.fill"
            )
            sourceRow(
                name: "Codex",
                tokens: usageStore.codexTokens,
                isHealthy: usageStore.codexHealthy,
                icon: "sparkle"
            )
            sourceRow(
                name: "Openclaw",
                tokens: usageStore.openclawTokens,
                isHealthy: usageStore.openclawHealthy,
                icon: "network"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sourceRow(name: String, tokens: Int, isHealthy: Bool, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isHealthy ? Color.secondary : Color.red)
                .frame(width: 16)
            Text(name)
                .font(.subheadline)
            Spacer()
            Text(UsageStore.formatTokens(tokens))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var tokenBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BREAKDOWN")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

            breakdownRow(label: "Prompt", value: usageStore.todayPromptTokens)
            breakdownRow(label: "Completion", value: usageStore.todayCompletionTokens)
            breakdownRow(label: "Cached", value: usageStore.todayCachedTokens)
            if usageStore.todayReasoningTokens > 0 {
                breakdownRow(label: "Reasoning", value: usageStore.todayReasoningTokens)
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
            Text("RECENT SESSIONS")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

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

                    Text(UsageStore.formatTokens(session.totalTokens))
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
                    sessionDetailRow("Prompt", session.promptTokens)
                    sessionDetailRow("Completion", session.completionTokens)
                    if session.cachedTokens > 0 {
                        sessionDetailRow("Cached", session.cachedTokens)
                    }
                    if session.reasoningTokens > 0 {
                        sessionDetailRow("Reasoning", session.reasoningTokens)
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
            Text("HISTORY")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

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
                    Text(UsageStore.formatTokens(day.totalTokens))
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
                            Text(UsageStore.formatTokens(session.totalTokens))
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
        case .roo: return .purple
        case .codex: return .green
        case .openclaw: return .orange
        }
    }

    private func sourceName(_ source: UsageEvent.Source) -> String {
        switch source {
        case .opencode: return "OC"
        case .roo: return "Roo"
        case .codex: return "Cdx"
        case .openclaw: return "OClw"
        }
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
