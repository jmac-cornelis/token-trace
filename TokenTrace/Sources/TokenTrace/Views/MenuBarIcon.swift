import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var usageStore: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")

            // Display unique work (new input + output + reasoning), not the provider
            // total, which double-counts re-sent context on every turn.
            if usageStore.todayUniqueWork > 0 {
                Text(UsageStore.formatTokens(usageStore.todayUniqueWork))
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }
}
