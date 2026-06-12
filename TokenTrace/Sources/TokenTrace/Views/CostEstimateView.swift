import SwiftUI

struct CostEstimateView: View {
    @EnvironmentObject var usageStore: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ESTIMATED COST")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

            if usageStore.isLoadingGrafana {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

            } else if let error = usageStore.grafanaError {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                .padding(.vertical, 4)

            } else if let estimate = usageStore.costEstimate {
                costBreakdown(estimate)

            } else {
                Text("No cost data available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Cost Breakdown

    @ViewBuilder
    private func costBreakdown(_ estimate: CostEstimate) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(CostEstimator.formatCost(estimate.totalEstimatedCost))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("likely billed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .help("Token-based estimate with no caching discount applied. The gateway reports no billing or cache data, so this uncached figure is the closest available proxy for the actual charge.")

        if !estimate.timeRange.isEmpty {
            Text(estimate.timeRange)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("In")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(UsageStore.formatTokens(estimate.totalInputTokens))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("Out")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(UsageStore.formatTokens(estimate.totalOutputTokens))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        if usageStore.todayCacheModeledCost > 0 {
            HStack(spacing: 4) {
                Text("with caching")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(CostEstimator.formatCost(usageStore.todayCacheModeledCost))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("floor")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.top, 2)
            .help("Lower bound assuming prompt caching applied to re-sent context (re-sent tokens billed at the 0.1× cache-read rate). Caching is rarely recorded, so the real charge is likely closer to the figure above.")
        }

        let visibleModels = estimate.perModelEstimates.filter { $0.requestPercentage > 0 }
        if !visibleModels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(visibleModels.enumerated()), id: \.offset) { _, model in
                    modelRow(model)
                }
            }
            .padding(.top, 4)
        }

        Text("Estimated from token counts × configured prices. The gateway provides no billing or caching data, so this is not an invoice.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    // MARK: - Per-Model Row

    private func modelRow(_ model: ModelCostEstimate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.modelName)
                    .font(.caption)
                    .lineLimit(1)

                Spacer()

                Text("\(Int((model.requestPercentage * 100).rounded()))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)

                Text(CostEstimator.formatCost(model.estimatedCost))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(
                            width: geometry.size.width * CGFloat(min(max(model.requestPercentage, 0), 1)),
                            height: 3
                        )
                }
            }
            .frame(height: 3)
        }
    }
}
