import SwiftUI
import Charts

struct UsageChartView: View {
    @EnvironmentObject var usageStore: UsageStore
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack {
                        Text("CUMULATIVE USAGE")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if isExpanded {
                    rangePicker
                }
            }

            if isExpanded {
                rangeSummary

                chart
                    .frame(height: 80)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { range in
                Button(action: { usageStore.setChartRange(range) }) {
                    Text(range.rawValue)
                        .font(.caption2)
                        .fontWeight(usageStore.chartRange == range ? .semibold : .regular)
                        .foregroundStyle(usageStore.chartRange == range ? .primary : .tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            usageStore.chartRange == range
                                ? Color.primary.opacity(0.08)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rangeSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(UsageStore.formatTokens(usageStore.rangeTotalTokens))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    Text("In")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(UsageStore.formatTokens(usageStore.rangePromptTokens))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("Out")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(UsageStore.formatTokens(usageStore.rangeCompletionTokens))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let billable = usageStore.rangeBillableTokens {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("Billable")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(UsageStore.formatTokens(Int(billable.totalBillableEquivalent.rounded())))
                            .font(.caption2)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                    if billable.cacheSavingsPercent > 0 {
                        Text("\(Int(billable.cacheSavingsPercent))% saved")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if usageStore.rangeEstimatedCost > 0 {
                        HStack(spacing: 4) {
                            Text("≈")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(CostEstimator.formatCost(usageStore.rangeEstimatedCost))
                                .font(.caption2)
                                .fontWeight(.medium)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart(usageStore.chartData) { point in
            BarMark(
                x: .value("Date", point.date, unit: chartUnit),
                y: .value("Tokens", point.totalTokens)
            )
            .foregroundStyle(Color.blue.opacity(0.6))
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: chartDateFormat)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text(UsageStore.formatTokens(intValue))
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                }
            }
        }
    }

    private var chartUnit: Calendar.Component {
        switch usageStore.chartRange {
        case .week, .month: return .day
        case .year: return .weekOfYear
        case .total: return .month
        }
    }

    private var chartDateFormat: Date.FormatStyle {
        switch usageStore.chartRange {
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day()
        case .year: return .dateTime.month(.abbreviated)
        case .total: return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }
}
