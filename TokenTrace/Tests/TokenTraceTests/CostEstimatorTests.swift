import Testing
import Foundation
@testable import TokenTrace

@Suite("CostEstimator pricing coverage")
struct CostEstimatorTests {

    // Pricing a 1M-token, input-only event returns exactly the per-million input
    // price; a 1M-token, output-only event returns the per-million output price.
    // This lets each test read the resolved price straight off the return value.
    private static let oneMillion = 1_000_000

    private func inputPrice(forModel model: String?) -> Double {
        CostEstimator.estimateCostFromEvents(
            promptTokens: Self.oneMillion,
            completionTokens: 0,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0,
            model: model,
            pricingTable: CostEstimator.defaultPricingTable
        )
    }

    private func outputPrice(forModel model: String?) -> Double {
        CostEstimator.estimateCostFromEvents(
            promptTokens: 0,
            completionTokens: Self.oneMillion,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            reasoningTokens: 0,
            model: model,
            pricingTable: CostEstimator.defaultPricingTable
        )
    }

    // MARK: - FIX #3: coverage gaps must not fall back to unknown ($3 / $15)

    @Test func developerFlashResolvesViaAliasToGeminiFlashPricing() {
        // "developer-flash" has no entry of its own; it must alias to
        // "developer-gemini-flash" (0.5 in / 3.0 out), NOT unknown (3.0 / 15.0).
        #expect(inputPrice(forModel: "developer-flash") == 0.5)
        #expect(outputPrice(forModel: "developer-flash") == 3.0)
    }

    @Test func developerFlashAliasIsCaseInsensitive() {
        #expect(inputPrice(forModel: "Developer-Flash") == 0.5)
    }

    @Test func gpt55HasItsOwnPricingNotUnknown() {
        // Codex rows store "gpt-5.5"; it must price at 2.5 / 15.0, not unknown.
        #expect(inputPrice(forModel: "gpt-5.5") == 2.5)
        #expect(outputPrice(forModel: "gpt-5.5") == 15.0)
    }

    @Test func gpt55XhighHasItsOwnPricing() {
        #expect(inputPrice(forModel: "gpt-5.5-xhigh") == 2.5)
        #expect(outputPrice(forModel: "gpt-5.5-xhigh") == 15.0)
    }

    // MARK: - Contrast: a genuinely unknown model still falls back to $3 / $15

    @Test func trulyUnknownModelFallsBackToUnknownPricing() {
        #expect(inputPrice(forModel: "totally-made-up-model-xyz") == 3.0)
        #expect(outputPrice(forModel: "totally-made-up-model-xyz") == 15.0)
    }

    @Test func nilModelFallsBackToUnknownPricing() {
        #expect(inputPrice(forModel: nil) == 3.0)
    }
}
