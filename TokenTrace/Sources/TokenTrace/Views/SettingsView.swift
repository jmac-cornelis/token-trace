import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SETTINGS")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                Text("Email")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                TextField("you@cornelisnetworks.com", text: $settings.grafanaUserEmail)
                    .font(.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            Picker("Mode", selection: $settings.dataSourceMode) {
                ForEach(DataSourceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.dataSourceMode == .grafana {
                grafanaConfigSection
            }

            Toggle("Show Cost Estimates", isOn: $settings.showCostEstimates)
                .font(.subheadline)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Grafana Config

    private var grafanaConfigSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: settings.isGrafanaConfigured
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(settings.isGrafanaConfigured ? .green : .yellow)

                Text(settings.isGrafanaConfigured ? "Connected" : "Enter email above")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                TextField("Grafana URL", text: $settings.grafanaBaseURL)
                    .font(.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }
}
