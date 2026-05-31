import Foundation

// MARK: - Pricing Model

/// Per-model pricing in dollars per 1 million tokens.
struct ModelPricing {
    let modelName: String
    let inputPricePerMillion: Double
    let outputPricePerMillion: Double
    let cacheReadPricePerMillion: Double?

    init(
        modelName: String,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        cacheReadPricePerMillion: Double? = nil
    ) {
        self.modelName = modelName
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheReadPricePerMillion = cacheReadPricePerMillion
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
struct BillableTokens {
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

        // --- Google Gemini ---
        ModelPricing(modelName: "gemini-3-1-pro",                           inputPricePerMillion: 2.0,   outputPricePerMillion: 12.0),
        ModelPricing(modelName: "gemini-3-flash",                           inputPricePerMillion: 0.5,   outputPricePerMillion: 3.0),

        // --- Other providers ---
        ModelPricing(modelName: "deepseek-v4-pro",                         inputPricePerMillion: 2.1,   outputPricePerMillion: 4.4,  cacheReadPricePerMillion: 0.2),
        ModelPricing(modelName: "zai-org/GLM-4.7",                         inputPricePerMillion: 0.6,   outputPricePerMillion: 2.2),
        ModelPricing(modelName: "kimi-k2.5",                                inputPricePerMillion: 0.5,   outputPricePerMillion: 2.8),

        // --- OpenCode modelID aliases (keys stored in $.modelID) ---
        ModelPricing(modelName: "developer-opus",                           inputPricePerMillion: 5.0,   outputPricePerMillion: 25.0),
        ModelPricing(modelName: "developer-opus-extended",                  inputPricePerMillion: 5.0,   outputPricePerMillion: 25.0),
        ModelPricing(modelName: "developer-sonnet",                         inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "developer-sonnet-4.6",                     inputPricePerMillion: 3.0,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "developer-codex",                          inputPricePerMillion: 1.75,  outputPricePerMillion: 14.0),
        ModelPricing(modelName: "developer-codex-max",                      inputPricePerMillion: 1.75,  outputPricePerMillion: 14.0),
        ModelPricing(modelName: "developer-gemini",                         inputPricePerMillion: 2.0,   outputPricePerMillion: 12.0),
        ModelPricing(modelName: "developer-gemini-flash",                   inputPricePerMillion: 0.5,   outputPricePerMillion: 3.0),
        ModelPricing(modelName: "developer-deepseek",                       inputPricePerMillion: 2.1,   outputPricePerMillion: 4.4,  cacheReadPricePerMillion: 0.2),
        ModelPricing(modelName: "developer-gpt",                            inputPricePerMillion: 2.5,   outputPricePerMillion: 30.0, cacheReadPricePerMillion: 0.25),
        ModelPricing(modelName: "developer-gpt-xhigh",                     inputPricePerMillion: 2.5,   outputPricePerMillion: 30.0, cacheReadPricePerMillion: 0.25),
        ModelPricing(modelName: "assistant-gpt",                            inputPricePerMillion: 2.5,   outputPricePerMillion: 30.0, cacheReadPricePerMillion: 0.25),
        ModelPricing(modelName: "developer-glm",                            inputPricePerMillion: 0.6,   outputPricePerMillion: 2.2),
        ModelPricing(modelName: "developer-kimi-k2.5",                     inputPricePerMillion: 0.5,   outputPricePerMillion: 2.8),
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
        pricingTable: [ModelPricing] = defaultPricingTable
    ) -> CostEstimate {
        let pricingLookup = pricingLookup(from: pricingTable)
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

    private static func pricingLookup(from pricingTable: [ModelPricing]) -> [String: ModelPricing] {
        Dictionary(uniqueKeysWithValues: pricingTable.map { ($0.modelName.lowercased(), $0) })
    }

    private static func pricing(
        for model: String?,
        pricingLookup: [String: ModelPricing]
    ) -> ModelPricing {
        guard let model else {
            return unknownModelPricing
        }

        return pricingLookup[model.lowercased()] ?? unknownModelPricing
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

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")

        if cost >= 1.0 {
            // Whole dollars with grouping separator, no cents.
            formatter.maximumFractionDigits = 0
        } else {
            // Sub-dollar: show cents.
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }

        return formatter.string(from: NSNumber(value: cost)) ?? "$0"
    }

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
        pricingTable: [ModelPricing] = defaultPricingTable
    ) -> Double {
        let pricingLookup = pricingLookup(from: pricingTable)
        let normalizedModel = canonicalModelName(model, pricingLookup: pricingLookup)
        let pricing = pricing(for: normalizedModel, pricingLookup: pricingLookup)

        let uncached = max(0, promptTokens - cachedReadTokens - cachedWriteTokens)
        let uncachedAndWriteInputCost = (Double(uncached) * uncachedMultiplier
            + Double(cachedWriteTokens) * cachedWriteMultiplier)
            * pricing.inputPricePerMillion / 1_000_000.0
        let cachedReadInputCost = Double(cachedReadTokens)
            * (pricing.cacheReadPricePerMillion ?? pricing.inputPricePerMillion * cachedReadMultiplier)
            / 1_000_000.0
        let inputCost = uncachedAndWriteInputCost + cachedReadInputCost

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
