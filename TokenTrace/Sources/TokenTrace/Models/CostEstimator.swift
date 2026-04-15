import Foundation

// MARK: - Pricing Model

/// Per-model pricing in dollars per 1 million tokens.
struct ModelPricing {
    let modelName: String
    let inputPricePerMillion: Double
    let outputPricePerMillion: Double
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
        ModelPricing(modelName: "developer-gpt",                            inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "developer-gpt-xhigh",                     inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
        ModelPricing(modelName: "developer-glm",                            inputPricePerMillion: 0.6,   outputPricePerMillion: 2.2),
        ModelPricing(modelName: "developer-kimi-k2.5",                     inputPricePerMillion: 0.5,   outputPricePerMillion: 2.8),
        ModelPricing(modelName: "assistant-gpt",                            inputPricePerMillion: 2.5,   outputPricePerMillion: 15.0),
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
        modelRequestCounts: [(model: String, count: Int)],
        pricingTable: [ModelPricing] = defaultPricingTable
    ) -> CostEstimate {

        // Edge case: no requests means no cost — return zeroed-out estimate.
        let totalRequests = modelRequestCounts.reduce(0) { $0 + $1.count }
        guard totalRequests > 0 else {
            return CostEstimate(
                totalEstimatedCost: 0,
                perModelEstimates: [],
                totalInputTokens: totalPromptTokens,
                totalOutputTokens: totalCompletionTokens,
                timeRange: "",
                caveats: Self.standardCaveats
            )
        }

        // Build a lookup from model name → pricing for O(1) access.
        let pricingLookup = Dictionary(
            uniqueKeysWithValues: pricingTable.map { ($0.modelName, $0) }
        )

        var perModelEstimates: [ModelCostEstimate] = []
        var totalCost = 0.0

        for entry in modelRequestCounts {
            // Skip models with zero requests — they contribute nothing.
            guard entry.count > 0 else { continue }

            // Proportion of total requests attributed to this model.
            let percentage = Double(entry.count) / Double(totalRequests)

            // Distribute aggregate tokens proportionally by request share.
            let inputTokens = Int((Double(totalPromptTokens) * percentage).rounded())
            let outputTokens = Int((Double(totalCompletionTokens) * percentage).rounded())

            // Look up pricing; fall back to mid-range estimate for unknown models.
            let pricing = pricingLookup[entry.model] ?? unknownModelPricing

            // Cost = tokens × (price per million / 1,000,000)
            let inputCost = Double(inputTokens) * pricing.inputPricePerMillion / 1_000_000.0
            let outputCost = Double(outputTokens) * pricing.outputPricePerMillion / 1_000_000.0
            let modelCost = inputCost + outputCost

            totalCost += modelCost

            perModelEstimates.append(ModelCostEstimate(
                modelName: entry.model,
                requestCount: entry.count,
                requestPercentage: percentage,
                estimatedInputTokens: inputTokens,
                estimatedOutputTokens: outputTokens,
                estimatedCost: modelCost
            ))
        }

        // Sort by cost descending so the most expensive model appears first.
        perModelEstimates.sort { $0.estimatedCost > $1.estimatedCost }

        return CostEstimate(
            totalEstimatedCost: totalCost,
            perModelEstimates: perModelEstimates,
            totalInputTokens: totalPromptTokens,
            totalOutputTokens: totalCompletionTokens,
            timeRange: "",
            caveats: Self.standardCaveats
        )
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
        let pricingLookup = Dictionary(
            uniqueKeysWithValues: pricingTable.map { ($0.modelName, $0) }
        )
        let pricing = model.flatMap { pricingLookup[$0] } ?? unknownModelPricing

        let uncached = max(0, promptTokens - cachedReadTokens - cachedWriteTokens)
        let inputCost = (Double(uncached) * uncachedMultiplier
            + Double(cachedReadTokens) * cachedReadMultiplier
            + Double(cachedWriteTokens) * cachedWriteMultiplier)
            * pricing.inputPricePerMillion / 1_000_000.0

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
