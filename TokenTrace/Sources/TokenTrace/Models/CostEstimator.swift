import Foundation

// MARK: - Pricing Model

/// Per-model pricing in dollars per 1 million tokens.
struct ModelPricing {
    let modelName: String
    let inputPricePerMillion: Double
    let outputPricePerMillion: Double
    let cacheReadPricePerMillion: Double?
    let cacheWritePricePerMillion: Double?

    init(
        modelName: String,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        cacheReadPricePerMillion: Double? = nil,
        cacheWritePricePerMillion: Double? = nil
    ) {
        self.modelName = modelName
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheReadPricePerMillion = cacheReadPricePerMillion
        self.cacheWritePricePerMillion = cacheWritePricePerMillion
    }
}

// MARK: - Billable Token Computation

/// Result of computing billable-equivalent tokens using provider cache pricing.
///
/// Anthropic prompt caching rates (relative to base input price):
/// - Uncached input:  1.0×  (full price)
/// - Cached read:     0.1×  (90% discount)
/// - Cached write:    1.25× (25% surcharge on first cache fill)
///
/// Output tokens (completion + reasoning) are always billed at full rate.
struct BillableTokens: Sendable {
    let uncachedInput: Int
    let cachedReadInput: Int
    let cachedWriteInput: Int
    let completionTokens: Int
    let reasoningTokens: Int
    let billableInputEquivalent: Double
    let totalBillableEquivalent: Double
    let cacheSavingsPercent: Double
}

// MARK: - Cost Estimation Results

/// Cost breakdown for a single model, including its share of tokens and estimated spend.
struct ModelCostEstimate {
    let modelName: String
    let requestCount: Int
    let requestPercentage: Double
    let estimatedInputTokens: Int
    let estimatedOutputTokens: Int
    let estimatedCost: Double
}

/// Aggregate cost estimate across all models for a given time range.
struct CostEstimate {
    let totalEstimatedCost: Double
    let perModelEstimates: [ModelCostEstimate]
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let timeRange: String
    let caveats: [String]
}

struct ModelRequestCount {
    let model: String?
    let count: Int
}

// MARK: - Cost Estimator

/// Namespace for cost estimation logic.
///
/// Estimation methodology:
/// 1. Loki provides aggregate prompt + completion token totals (no model info).
/// 2. PostgreSQL provides per-model request counts.
/// 3. We compute each model's share of total requests as a percentage.
/// 4. We distribute the aggregate tokens proportionally by that percentage.
/// 5. We apply each model's per-token pricing to its allocated tokens.
///
/// This is a rough estimate because token-per-request ratios vary by model
/// (e.g., opus requests tend to use more tokens than mini requests).
enum CostEstimator {

    // MARK: - Default Pricing Table

    /// Known model pricing as of April 2026 (dollars per 1M tokens).
    /// Includes both canonical model names and OpenCode modelID aliases,
    /// since OpenCode stores the config key (e.g. "developer-opus") in $.modelID.
    static let defaultPricingTable: [ModelPricing] = [
        // --- Anthropic Claude ---
        ModelPricing(modelName: "claude-opus-4-6",                          inputPricePerMillion: 5.0,   outputPricePerMillion: 25.0),
        ModelPricing(modelName: "claude-opus-4-6-extended",                 inputPricePerMillion: 5.0,   outputPricePerMillion: 25.0),
        ModelPricing(modelName: "claude-sonnet-4-5",                        inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "claude-sonnet-4-6",                        inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "asic:claude-sonnet-4-5",                   inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0),

        // --- OpenAI GPT / Codex ---
        ModelPricing(modelName: "gpt-5.3-codex",                            inputPricePerMillion: 1.75,  outputPricePerMillion: 14.0),
        ModelPricing(modelName: "gpt-5.3-codex-max",                        inputPricePerMillion: 1.75,  outputPricePerMillion: 14.0),
        ModelPricing(modelName: "gpt-5.4",                                  inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "gpt-5.4-xhigh",                           inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "assistant-gpt-5.4",                        inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "gpt-5.5",                                  inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "gpt-5.5-xhigh",                           inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),

        // --- Google Gemini ---
        ModelPricing(modelName: "gemini-3-1-pro",                           inputPricePerMillion: 2.0,   outputPricePerMillion: 12.0),
        ModelPricing(modelName: "gemini-3-flash",                           inputPricePerMillion: 0.5,   outputPricePerMillion: 3.0),

        // --- Other providers ---
        ModelPricing(modelName: "deepseek-v4-pro",                         inputPricePerMillion: 2.1,   outputPricePerMillion: 4.4,  cacheReadPricePerMillion: 0.2),
        ModelPricing(modelName: "zai-org/GLM-4.7",                         inputPricePerMillion: 0.6,   outputPricePerMillion: 2.2),
        ModelPricing(modelName: "kimi-k2.5",                                inputPricePerMillion: 0.5,   outputPricePerMillion: 2.8),

        // --- OpenCode modelID aliases (keys stored in $.modelID) ---
        ModelPricing(modelName: "developer-opus",                           inputPricePerMillion: 4.0,   outputPricePerMillion: 20.0, cacheReadPricePerMillion: 0.2,   cacheWritePricePerMillion: 5.0),
        ModelPricing(modelName: "developer-opus-extended",                  inputPricePerMillion: 4.0,   outputPricePerMillion: 20.0, cacheReadPricePerMillion: 0.2,   cacheWritePricePerMillion: 5.0),
        ModelPricing(modelName: "developer-sonnet",                         inputPricePerMillion: 2.0,   outputPricePerMillion: 10.0, cacheReadPricePerMillion: 0.2,   cacheWritePricePerMillion: 2.5),
        ModelPricing(modelName: "developer-sonnet-4.6",                     inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0, cacheReadPricePerMillion: 0.3,   cacheWritePricePerMillion: 3.75),
        ModelPricing(modelName: "developer-codex",                          inputPricePerMillion: 1.75,  outputPricePerMillion: 14.0),
        ModelPricing(modelName: "developer-codex-max",                      inputPricePerMillion: 1.75,  outputPricePerMillion: 14.0),
        ModelPricing(modelName: "developer-gemini",                         inputPricePerMillion: 2.0,   outputPricePerMillion: 12.0, cacheReadPricePerMillion: 0.2),
        ModelPricing(modelName: "developer-gemini-flash",                   inputPricePerMillion: 0.5,   outputPricePerMillion: 3.0,  cacheReadPricePerMillion: 0.15),
        ModelPricing(modelName: "developer-deepseek",                       inputPricePerMillion: 2.1,   outputPricePerMillion: 4.4,  cacheReadPricePerMillion: 0.2),
        ModelPricing(modelName: "developer-deepseek-flash",                 inputPricePerMillion: 0.9,   outputPricePerMillion: 0.9,  cacheReadPricePerMillion: 0.45),
        ModelPricing(modelName: "developer-gpt",                            inputPricePerMillion: 2.5,   outputPricePerMillion: 30.0, cacheReadPricePerMillion: 0.25),
        ModelPricing(modelName: "developer-gpt-xhigh",                     inputPricePerMillion: 2.5,   outputPricePerMillion: 30.0, cacheReadPricePerMillion: 0.25),
        ModelPricing(modelName: "assistant-gpt",                            inputPricePerMillion: 2.5,   outputPricePerMillion: 30.0, cacheReadPricePerMillion: 0.25),
        ModelPricing(modelName: "developer-glm",                            inputPricePerMillion: 2.1,   outputPricePerMillion: 6.6,  cacheReadPricePerMillion: 0.39),
        ModelPricing(modelName: "developer-kimi-k2.5",                     inputPricePerMillion: 0.5,   outputPricePerMillion: 2.8),
        ModelPricing(modelName: "developer-qwen",                           inputPricePerMillion: 2.0,   outputPricePerMillion: 6.0,  cacheReadPricePerMillion: 0.25),
        // These 7 account for ~27K stored events (developer-sol-xhigh alone is 14,318).
        // They must exist here, not only in opencode.json: PricingConfigLoader returns an
        // empty table on any parse failure, and a single bad edit to that file would
        // silently drop them to $0 rather than surfacing an error.
        ModelPricing(modelName: "developer-sol",                            inputPricePerMillion: 2.0,   outputPricePerMillion: 10.0, cacheReadPricePerMillion: 0.2,   cacheWritePricePerMillion: 2.0),
        ModelPricing(modelName: "developer-sol-xhigh",                      inputPricePerMillion: 2.0,   outputPricePerMillion: 10.0, cacheReadPricePerMillion: 0.2,   cacheWritePricePerMillion: 2.0),
        ModelPricing(modelName: "developer-terra",                          inputPricePerMillion: 2.0,   outputPricePerMillion: 10.0, cacheReadPricePerMillion: 0.05,  cacheWritePricePerMillion: 1.0),
        ModelPricing(modelName: "developer-luna",                           inputPricePerMillion: 0.1,   outputPricePerMillion: 0.5,  cacheReadPricePerMillion: 0.01,  cacheWritePricePerMillion: 0.125),
        ModelPricing(modelName: "developer-minimax",                        inputPricePerMillion: 0.3,   outputPricePerMillion: 1.2,  cacheReadPricePerMillion: 0.1),
        ModelPricing(modelName: "developer-opus-5",                         inputPricePerMillion: 4.0,   outputPricePerMillion: 20.0, cacheReadPricePerMillion: 0.2,   cacheWritePricePerMillion: 5.0),
        ModelPricing(modelName: "developer-argon",                          inputPricePerMillion: 2.0,   outputPricePerMillion: 10.0, cacheReadPricePerMillion: 0.1),
        ModelPricing(modelName: "developer-gemini-argon",                   inputPricePerMillion: 2.0,   outputPricePerMillion: 10.0, cacheReadPricePerMillion: 0.1),
        ModelPricing(modelName: "developer-ember",                          inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0, cacheReadPricePerMillion: 0.3),
        ModelPricing(modelName: "developer-astra",                          inputPricePerMillion: 10.0,  outputPricePerMillion: 50.0, cacheReadPricePerMillion: 1.0),
        ModelPricing(modelName: "developer-fable",                          inputPricePerMillion: 10.0,  outputPricePerMillion: 50.0, cacheReadPricePerMillion: 0.25,  cacheWritePricePerMillion: 12.5),
        ModelPricing(modelName: "developer-glm-flash",                      inputPricePerMillion: 0.15,  outputPricePerMillion: 0.5,  cacheReadPricePerMillion: 0.03),
        ModelPricing(modelName: "developer-opus-4.6",                       inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0, cacheReadPricePerMillion: 0.3),
        ModelPricing(modelName: "fable-5",                                  inputPricePerMillion: 5.0,   outputPricePerMillion: 25.0, cacheReadPricePerMillion: 0.5),
        ModelPricing(modelName: "cn_asic:react_local:claude-sonnet-4-5",   inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0),

        // --- Legacy models (kept for historical cost estimation) ---
        ModelPricing(modelName: "gemini-3-pro",                             inputPricePerMillion: 1.25,  outputPricePerMillion: 10.0),
        ModelPricing(modelName: "gpt-5.4-high",                             inputPricePerMillion: 2.50,  outputPricePerMillion: 10.0),
        ModelPricing(modelName: "gpt-5.2",                                  inputPricePerMillion: 2.0,   outputPricePerMillion: 8.0),
        ModelPricing(modelName: "gpt-5.1-codex-mini",                       inputPricePerMillion: 0.50,  outputPricePerMillion: 3.0),
    ]

    /// Fallback pricing for models not in the pricing table.
    /// Uses a mid-range estimate ($3 input / $15 output per 1M tokens).
    private static let unknownModelPricing = ModelPricing(
        modelName: "unknown",
        inputPricePerMillion: 3.0,
        outputPricePerMillion: 15.0
    )

    // MARK: - Model Aliases

    /// Maps stored model strings to their priced equivalent when the stored name
    /// has no pricing entry of its own. Keys/values are lowercased; the value
    /// must resolve in the active pricing table. Example: OpenCode stores
    /// "developer-flash", but the priced config key is "developer-gemini-flash".
    static let modelAliases: [String: String] = [
        "developer-flash": "developer-gemini-flash",
        "developer-kimi": "developer-kimi-k2.5",
    ]

    // MARK: - Effective-Dated Pricing

    /// A price that was in effect only before `endingBefore`.
    struct HistoricalPricing {
        let endingBefore: Date
        let pricing: ModelPricing
    }

    /// Cornelis raised `developer-gpt` and `developer-codex-max` from $2.50/$15.00 to
    /// $5.00/$30.00 at the start of May 2026. Every turn we have to price ourselves for
    /// those two models predates that change, so charging current rates overbills by
    /// $1,412.56. Ordered oldest-first; the first entry whose `endingBefore` is after the
    /// event wins. Models whose rates never moved are deliberately absent.
    static let historicalPricingTable: [String: [HistoricalPricing]] = [
        "developer-gpt": [
            HistoricalPricing(
                endingBefore: Date(timeIntervalSince1970: 1_777_593_600),
                pricing: ModelPricing(modelName: "developer-gpt", inputPricePerMillion: 2.5, outputPricePerMillion: 15.0, cacheReadPricePerMillion: 0.25)
            ),
        ],
        "developer-gpt-xhigh": [
            HistoricalPricing(
                endingBefore: Date(timeIntervalSince1970: 1_777_593_600),
                pricing: ModelPricing(modelName: "developer-gpt-xhigh", inputPricePerMillion: 2.5, outputPricePerMillion: 15.0, cacheReadPricePerMillion: 0.25)
            ),
        ],
        "developer-codex-max": [
            HistoricalPricing(
                endingBefore: Date(timeIntervalSince1970: 1_777_593_600),
                pricing: ModelPricing(modelName: "developer-codex-max", inputPricePerMillion: 2.5, outputPricePerMillion: 15.0, cacheReadPricePerMillion: 0.25)
            ),
        ],
    ]

    // MARK: - Dynamic (config-driven) Pricing

    /// Active table for all estimation methods. `reloadConfiguredPricing()`
    /// overlays `opencode.json` prices on top of these defaults at launch.
    /// `nonisolated(unsafe)`: written once at startup before any reader runs,
    /// read-only thereafter — annotating it otherwise would invite a bogus
    /// "fix" that adds a real data race.
    nonisolated(unsafe) static var configuredPricingTable: [ModelPricing] = defaultPricingTable

    // Perf: lookup is rebuilt 3x per refresh; configuredPricingTable is write-once
    // at startup so cache the derived dictionary and rebuild only in reloadConfiguredPricing.
    nonisolated(unsafe) static var configuredPricingLookup: [String: ModelPricing] =
        buildPricingLookup(from: defaultPricingTable)

    /// Overlays `opencode.json` prices on the built-in defaults (config wins
    /// per model name; defaults remain fallbacks). Missing/unparseable config
    /// leaves the defaults untouched. `explicitPath` overrides the search path.
    @discardableResult
    static func reloadConfiguredPricing(from explicitPath: String? = nil) -> [ModelPricing] {
        let configured = PricingConfigLoader.loadPricing(from: explicitPath)
        configuredPricingTable = mergePricing(defaults: defaultPricingTable, overrides: configured)
        configuredPricingLookup = buildPricingLookup(from: configuredPricingTable)
        return configuredPricingTable
    }

    /// Merges two pricing lists; `overrides` win over `defaults` for the same
    /// model name (case-insensitive), default ordering preserved.
    static func mergePricing(defaults: [ModelPricing], overrides: [ModelPricing]) -> [ModelPricing] {
        var byName: [String: ModelPricing] = [:]
        var order: [String] = []

        func upsert(_ pricing: ModelPricing) {
            let key = pricing.modelName.lowercased()
            if let existing = byName[key] {
                byName[key] = ModelPricing(
                    modelName: pricing.modelName,
                    inputPricePerMillion: pricing.inputPricePerMillion,
                    outputPricePerMillion: pricing.outputPricePerMillion,
                    cacheReadPricePerMillion: pricing.cacheReadPricePerMillion ?? existing.cacheReadPricePerMillion,
                    cacheWritePricePerMillion: pricing.cacheWritePricePerMillion ?? existing.cacheWritePricePerMillion
                )
            } else {
                order.append(key)
                byName[key] = pricing
            }
        }

        defaults.forEach(upsert)
        overrides.forEach(upsert)

        return order.compactMap { byName[$0] }
    }

    // MARK: - Estimation

    /// Estimate costs by distributing aggregate tokens across models proportionally
    /// by request count, then applying per-model pricing.
    ///
    /// - Parameters:
    ///   - totalPromptTokens: Aggregate input/prompt tokens from Loki.
    ///   - totalCompletionTokens: Aggregate output/completion tokens from Loki.
    ///   - modelRequestCounts: Per-model request counts from PostgreSQL.
    ///   - pricingTable: Per-model pricing; defaults to `defaultPricingTable`.
    /// - Returns: A `CostEstimate` with per-model breakdown and total.
    static func estimate(
        totalPromptTokens: Int,
        totalCompletionTokens: Int,
        modelRequestCounts: [ModelRequestCount],
        pricingTable: [ModelPricing]? = nil
    ) -> CostEstimate {
        let pricingLookup = lookup(for: pricingTable)
        let sanitizedRequestCounts = sanitizeModelRequestCounts(
            modelRequestCounts,
            pricingLookup: pricingLookup
        )
        let totalRequests = sanitizedRequestCounts.reduce(0) { $0 + $1.count }

        guard totalRequests > 0 else {
            return CostEstimate(
                totalEstimatedCost: estimateCostFromEvents(
                    promptTokens: totalPromptTokens,
                    completionTokens: totalCompletionTokens,
                    cachedReadTokens: 0,
                    cachedWriteTokens: 0,
                    reasoningTokens: 0,
                    model: nil,
                    pricingTable: pricingTable
                ),
                perModelEstimates: [],
                totalInputTokens: totalPromptTokens,
                totalOutputTokens: totalCompletionTokens,
                timeRange: "",
                caveats: Self.standardCaveats
            )
        }

        var perModelEstimates: [ModelCostEstimate] = []
        var totalCost = 0.0

        for entry in sanitizedRequestCounts {
            guard let modelName = entry.model else {
                continue
            }

            let percentage = Double(entry.count) / Double(totalRequests)
            let inputTokens = Int((Double(totalPromptTokens) * percentage).rounded())
            let outputTokens = Int((Double(totalCompletionTokens) * percentage).rounded())
            let pricing = pricing(for: modelName, pricingLookup: pricingLookup)
            let inputCost = Double(inputTokens) * pricing.inputPricePerMillion / 1_000_000.0
            let outputCost = Double(outputTokens) * pricing.outputPricePerMillion / 1_000_000.0
            let modelCost = inputCost + outputCost

            totalCost += modelCost

            perModelEstimates.append(ModelCostEstimate(
                modelName: modelName,
                requestCount: entry.count,
                requestPercentage: percentage,
                estimatedInputTokens: inputTokens,
                estimatedOutputTokens: outputTokens,
                estimatedCost: modelCost
            ))
        }

        perModelEstimates.sort {
            if $0.estimatedCost != $1.estimatedCost {
                return $0.estimatedCost > $1.estimatedCost
            }
            if $0.requestCount != $1.requestCount {
                return $0.requestCount > $1.requestCount
            }
            return $0.modelName.localizedCaseInsensitiveCompare($1.modelName) == .orderedAscending
        }

        return CostEstimate(
            totalEstimatedCost: totalCost,
            perModelEstimates: perModelEstimates,
            totalInputTokens: totalPromptTokens,
            totalOutputTokens: totalCompletionTokens,
            timeRange: "",
            caveats: Self.standardCaveats
        )
    }

    private static let ignoredModelIdentifiers: Set<String> = [
        "anthropic",
        "cornelis",
        "google",
        "openai",
        "unknown",
    ]

    private static func sanitizeModelRequestCounts(
        _ modelRequestCounts: [ModelRequestCount],
        pricingLookup: [String: ModelPricing]
    ) -> [ModelRequestCount] {
        var aggregatedCounts: [String: Int] = [:]

        for entry in modelRequestCounts {
            guard entry.count > 0,
                  let modelName = canonicalModelName(entry.model, pricingLookup: pricingLookup) else {
                continue
            }

            aggregatedCounts[modelName, default: 0] += entry.count
        }

        return aggregatedCounts
            .sorted { lhs, rhs in
                lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { ModelRequestCount(model: $0.key, count: $0.value) }
    }

    private static func canonicalModelName(
        _ rawModel: String?,
        pricingLookup: [String: ModelPricing]
    ) -> String? {
        guard let trimmed = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let lookupKey = trimmed.lowercased()
        if let pricing = pricingLookup[lookupKey] {
            return pricing.modelName
        }

        if ignoredModelIdentifiers.contains(lookupKey) {
            return nil
        }

        return trimmed
    }

    static func buildPricingLookup(from pricingTable: [ModelPricing]) -> [String: ModelPricing] {
        Dictionary(uniqueKeysWithValues: pricingTable.map { ($0.modelName.lowercased(), $0) })
    }

    private static func lookup(for pricingTable: [ModelPricing]?) -> [String: ModelPricing] {
        guard let pricingTable else { return configuredPricingLookup }
        return buildPricingLookup(from: pricingTable)
    }

    /// Whether `model` resolves to a real pricing entry rather than the mid-range
    /// `unknownModelPricing` guess. Callers that synthesize missing costs use this to
    /// avoid inventing spend for models with no published price (e.g. "assistant",
    /// which `opencode.json` declares with no `cost` block).
    static func hasKnownPricing(for model: String?, pricingTable: [ModelPricing]? = nil) -> Bool {
        guard let key = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty else {
            return false
        }
        let pricingLookup = lookup(for: pricingTable)
        if pricingLookup[key] != nil { return true }
        if let aliased = modelAliases[key] { return pricingLookup[aliased] != nil }
        return false
    }

    private static func pricing(
        for model: String?,
        pricingLookup: [String: ModelPricing],
        observedAt: Date? = nil
    ) -> ModelPricing {
        guard let model else {
            return unknownModelPricing
        }

        let key = model.lowercased()
        if let observedAt, let historical = historicalPricing(for: key, observedAt: observedAt) {
            return historical
        }
        if let direct = pricingLookup[key] {
            return direct
        }
        if let aliased = modelAliases[key], let viaAlias = pricingLookup[aliased] {
            return viaAlias
        }
        return unknownModelPricing
    }

    private static func historicalPricing(for key: String, observedAt: Date) -> ModelPricing? {
        guard let eras = historicalPricingTable[key] else { return nil }
        return eras.first { observedAt < $0.endingBefore }?.pricing
    }

    // MARK: - Formatting

    /// Format a dollar amount for display.
    /// - Values >= $1 are shown as whole dollars with grouping: "$1,234"
    /// - Values < $1 are shown with cents: "$0.50"
    /// - Zero is shown as "$0"
    static func formatCost(_ cost: Double) -> String {
        if cost == 0 {
            return "$0"
        }

        // Static formatters: NumberFormatter alloc is costly and this runs per cost-row render.
        let formatter = cost >= 1.0 ? Self.wholeDollarFormatter : Self.centsFormatter
        return formatter.string(from: NSNumber(value: cost)) ?? "$0"
    }

    private static let wholeDollarFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let centsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    // MARK: - Billable Token Computation

    static let cachedReadMultiplier  = 0.1
    static let cachedWriteMultiplier = 1.25
    static let uncachedMultiplier    = 1.0

    static func computeBillableTokens(
        promptTokens: Int,
        completionTokens: Int,
        cachedReadTokens: Int,
        cachedWriteTokens: Int,
        reasoningTokens: Int
    ) -> BillableTokens {
        let uncached = max(0, promptTokens - cachedReadTokens - cachedWriteTokens)

        let billableInput = Double(uncached) * uncachedMultiplier
            + Double(cachedReadTokens) * cachedReadMultiplier
            + Double(cachedWriteTokens) * cachedWriteMultiplier

        let billableOutput = Double(completionTokens + reasoningTokens)
        let totalBillable = billableInput + billableOutput

        let rawInput = Double(promptTokens)
        let savings = rawInput > 0
            ? ((rawInput - billableInput) / rawInput) * 100.0
            : 0.0

        return BillableTokens(
            uncachedInput: uncached,
            cachedReadInput: cachedReadTokens,
            cachedWriteInput: cachedWriteTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens,
            billableInputEquivalent: billableInput,
            totalBillableEquivalent: totalBillable,
            cacheSavingsPercent: savings
        )
    }

    static func estimateCostFromEvents(
        promptTokens: Int,
        completionTokens: Int,
        cachedReadTokens: Int,
        cachedWriteTokens: Int,
        reasoningTokens: Int,
        model: String?,
        pricingTable: [ModelPricing]? = nil,
        observedAt: Date? = nil
    ) -> Double {
        let pricingLookup = lookup(for: pricingTable)
        let normalizedModel = canonicalModelName(model, pricingLookup: pricingLookup)
        let pricing = pricing(for: normalizedModel, pricingLookup: pricingLookup, observedAt: observedAt)

        let uncached = max(0, promptTokens - cachedReadTokens - cachedWriteTokens)
        let cacheReadRate = pricing.cacheReadPricePerMillion ?? pricing.inputPricePerMillion * cachedReadMultiplier
        let cacheWriteRate = pricing.cacheWritePricePerMillion ?? pricing.inputPricePerMillion * cachedWriteMultiplier
        let uncachedAndWriteInputCost = Double(uncached) * uncachedMultiplier * pricing.inputPricePerMillion / 1_000_000.0
            + Double(cachedWriteTokens) * cacheWriteRate / 1_000_000.0
        let cachedReadInputCost = Double(cachedReadTokens) * cacheReadRate / 1_000_000.0
        let inputCost = uncachedAndWriteInputCost + cachedReadInputCost

        let outputCost = Double(completionTokens + reasoningTokens)
            * pricing.outputPricePerMillion / 1_000_000.0

        return inputCost + outputCost
    }

    static func estimateCacheModeledCost(
        promptTokens: Int,
        newInputTokens: Int,
        completionTokens: Int,
        cachedReadTokens: Int,
        cachedWriteTokens: Int,
        reasoningTokens: Int,
        model: String?,
        pricingTable: [ModelPricing]? = nil
    ) -> Double {
        let pricingLookup = lookup(for: pricingTable)
        let normalizedModel = canonicalModelName(model, pricingLookup: pricingLookup)
        let pricing = pricing(for: normalizedModel, pricingLookup: pricingLookup)
        let cacheReadRate = pricing.cacheReadPricePerMillion ?? pricing.inputPricePerMillion * cachedReadMultiplier
        let cacheWriteRate = pricing.cacheWritePricePerMillion ?? pricing.inputPricePerMillion * cachedWriteMultiplier

        let inputCost: Double
        if cachedReadTokens + cachedWriteTokens > 0 {
            let uncached = max(0, promptTokens - cachedReadTokens - cachedWriteTokens)
            inputCost = Double(uncached) * uncachedMultiplier * pricing.inputPricePerMillion / 1_000_000.0
                + Double(cachedWriteTokens) * cacheWriteRate / 1_000_000.0
                + Double(cachedReadTokens) * cacheReadRate / 1_000_000.0
        } else {
            // No provider cache split recorded: treat the re-sent prefix (prompt - new) as a
            // cache hit at the read rate; only genuinely new input pays the full input rate.
            let newInput = max(0, min(newInputTokens, promptTokens))
            let resent = promptTokens - newInput
            inputCost = Double(newInput) * pricing.inputPricePerMillion / 1_000_000.0
                + Double(resent) * cacheReadRate / 1_000_000.0
        }

        let outputCost = Double(completionTokens + reasoningTokens)
            * pricing.outputPricePerMillion / 1_000_000.0

        return inputCost + outputCost
    }

    // MARK: - Caveats

    private static let standardCaveats: [String] = [
        "Rough estimate — token-per-request ratio varies by model",
        "Loki logs don't include model — per-model split is estimated from request counts",
    ]
}
