import Foundation

// MARK: - Data Source Mode

/// Determines whether token usage data is read from local source databases
/// or fetched from a remote Grafana instance.
enum DataSourceMode: String, Codable, CaseIterable {
    /// Client-side: reads directly from local tool databases (default behavior).
    case local
    /// Server-side: queries a Grafana API for aggregated usage data.
    case grafana

    /// Human-readable label for use in UI pickers.
    var displayName: String {
        switch self {
        case .local:   return "Client-Side (Local)"
        case .grafana: return "Server-Side (Grafana)"
        }
    }
}

// MARK: - Settings Manager

/// Persists user preferences via UserDefaults and publishes changes for SwiftUI.
///
/// All keys are prefixed with `tokenTrace.` to avoid collisions with other
/// defaults in the same suite.
@MainActor
final class SettingsManager: ObservableObject {

    // MARK: Singleton

    static let shared = SettingsManager()

    // MARK: UserDefaults Keys

    private enum Keys {
        static let dataSourceMode    = "tokenTrace.dataSourceMode"
        static let grafanaBaseURL    = "tokenTrace.grafanaBaseURL"
        static let grafanaUserEmail  = "tokenTrace.grafanaUserEmail"
        static let showCostEstimates = "tokenTrace.showCostEstimates"
    }

    // MARK: Default Values

    private enum Defaults {
        static let dataSourceMode: DataSourceMode = .local
        static let grafanaBaseURL    = "http://cn-ai-01.cornelisnetworks.com:4000"
        static let grafanaUserEmail  = ""
        static let showCostEstimates = true
    }

    // MARK: Published Settings

    /// Controls whether the app reads from local databases or a Grafana server.
    @Published var dataSourceMode: DataSourceMode {
        didSet { defaults.set(dataSourceMode.rawValue, forKey: Keys.dataSourceMode) }
    }

    /// Base URL for the Grafana instance (e.g. "http://host:4000").
    @Published var grafanaBaseURL: String {
        didSet { defaults.set(grafanaBaseURL, forKey: Keys.grafanaBaseURL) }
    }

    /// Email address used to identify the user in Grafana queries.
    @Published var grafanaUserEmail: String {
        didSet { defaults.set(grafanaUserEmail, forKey: Keys.grafanaUserEmail) }
    }

    /// Whether to display estimated cost alongside token counts.
    @Published var showCostEstimates: Bool {
        didSet { defaults.set(showCostEstimates, forKey: Keys.showCostEstimates) }
    }

    // MARK: Computed Properties

    /// `true` when the Grafana user email has been provided (non-empty after trimming).
    var isGrafanaConfigured: Bool {
        !grafanaUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Constructs a `URL` from the stored Grafana base URL string, or `nil` if invalid.
    var grafanaAPIBaseURL: URL? {
        URL(string: grafanaBaseURL)
    }

    // MARK: Private

    private let defaults: UserDefaults

    // MARK: Init

    /// Loads persisted settings from UserDefaults, falling back to built-in defaults.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to use. Defaults to `.standard`.
    ///   Pass a custom suite in tests to avoid polluting the real store.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // --- Data source mode ---
        // Read the raw string and attempt to map it to a DataSourceMode case.
        if let raw = defaults.string(forKey: Keys.dataSourceMode),
           let mode = DataSourceMode(rawValue: raw) {
            self.dataSourceMode = mode
        } else {
            self.dataSourceMode = Defaults.dataSourceMode
        }

        // --- Grafana base URL ---
        // Use the stored value if present; otherwise fall back to the default.
        if let stored = defaults.string(forKey: Keys.grafanaBaseURL) {
            self.grafanaBaseURL = stored
        } else {
            self.grafanaBaseURL = Defaults.grafanaBaseURL
        }

        // --- Grafana user email ---
        if let stored = defaults.string(forKey: Keys.grafanaUserEmail) {
            self.grafanaUserEmail = stored
        } else {
            self.grafanaUserEmail = Defaults.grafanaUserEmail
        }

        // --- Cost estimates toggle ---
        // UserDefaults returns false for unregistered bool keys, so we check
        // whether the key exists before reading to distinguish "never set" from
        // "explicitly set to false".
        if defaults.object(forKey: Keys.showCostEstimates) != nil {
            self.showCostEstimates = defaults.bool(forKey: Keys.showCostEstimates)
        } else {
            self.showCostEstimates = Defaults.showCostEstimates
        }
    }
}
