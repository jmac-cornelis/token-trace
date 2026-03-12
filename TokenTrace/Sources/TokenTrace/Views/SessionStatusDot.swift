import SwiftUI

struct SessionStatusDot: View {
    let status: SessionSummary.ActivityStatus
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                status == .active
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if status == .active {
                    isPulsing = true
                }
            }
            .onChange(of: status) { _, newStatus in
                isPulsing = newStatus == .active
            }
    }

    private var dotColor: Color {
        switch status {
        case .active: return .green
        case .idle: return .yellow
        case .stale: return .gray
        }
    }
}
