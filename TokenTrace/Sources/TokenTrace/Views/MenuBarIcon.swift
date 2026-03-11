import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var usageStore: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")

            // Show compact token count if > 0
            if usageStore.todayTotalTokens > 0 {
                Text(UsageStore.formatTokens(usageStore.todayTotalTokens))
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }
}
