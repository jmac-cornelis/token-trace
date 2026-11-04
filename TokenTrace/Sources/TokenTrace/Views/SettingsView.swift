import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SETTINGS")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

            remoteConfigSection

            Toggle("Show Cost Estimates", isOn: $settings.showCostEstimates)
                .font(.subheadline)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Remote SSH Config

    private var remoteConfigSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Sync Remote Hermes/OpenCode", isOn: $settings.remoteSyncEnabled)
                .font(.subheadline)
                .toggleStyle(.switch)
                .controlSize(.small)

            if settings.remoteSyncEnabled {
                HStack(spacing: 6) {
                    Text("Host")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    TextField("ai-devsrvr-11", text: $settings.remoteSSHHost)
                        .font(.subheadline)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }
}
