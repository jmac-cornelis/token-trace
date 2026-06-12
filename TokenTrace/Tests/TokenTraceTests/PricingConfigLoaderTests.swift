import Testing
import Foundation
@testable import TokenTrace

@Suite("PricingConfigLoader")
struct PricingConfigLoaderTests {

    // MARK: - stripJSONComments

    @Test func stripsLineAndBlockComments() {
        let jsonc = """
        {
            // leading line comment
            "a": 1, // trailing line comment
            /* block
               comment */
            "b": 2
        }
        """
        let cleaned = PricingConfigLoader.stripJSONComments(jsonc)
        #expect(!cleaned.contains("leading line comment"))
        #expect(!cleaned.contains("trailing line comment"))
        #expect(!cleaned.contains("block"))

        // Must remain valid JSON after stripping.
        let data = cleaned.data(using: .utf8)!
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["a"] as? Int == 1)
        #expect(obj?["b"] as? Int == 2)
    }

    @Test func preservesURLsInsideStringLiterals() {
        // A "//" inside a string literal (e.g. a baseURL) must NOT be treated
        // as a comment — this is the critical regression guard.
        let jsonc = """
        {
            "baseURL": "http://cn-ai-01.cornelisnetworks.com:50800/v1", // real comment
            "note": "path /* not a comment */ here"
        }
        """
        let cleaned = PricingConfigLoader.stripJSONComments(jsonc)
        let data = cleaned.data(using: .utf8)!
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["baseURL"] as? String == "http://cn-ai-01.cornelisnetworks.com:50800/v1")
        #expect(obj?["note"] as? String == "path /* not a comment */ here")
    }

    @Test func preservesEscapedQuotesInStrings() {
        // An escaped quote inside a string must not prematurely end the string
        // state and expose a following // as a comment.
        let jsonc = #"""
        {
            "quoted": "he said \"hi\" // still in string",
            "x": 1
        }
        """#
        let cleaned = PricingConfigLoader.stripJSONComments(jsonc)
        let data = cleaned.data(using: .utf8)!
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["quoted"] as? String == "he said \"hi\" // still in string")
        #expect(obj?["x"] as? Int == 1)
    }

    // MARK: - parsePricing

    @Test func parsesInputOutputAndCacheRead() {
        let jsonc = """
        {
            "provider": {
                "cornelis": {
                    "models": {
                        "developer-opus-extended": {
                            "id": "developer-opus-extended",
                            "cost": { "input": 5, "output": 25, "cache_read": 0.5 }
                        }
                    }
                }
            }
        }
        """
        let pricing = PricingConfigLoader.parsePricing(fromJSONC: jsonc)
        #expect(pricing.count == 1)
        let p = pricing[0]
        #expect(p.modelName == "developer-opus-extended")
        #expect(p.inputPricePerMillion == 5)
        #expect(p.outputPricePerMillion == 25)
        #expect(p.cacheReadPricePerMillion == 0.5)
    }

    @Test func cacheReadIsOptional() {
        let jsonc = """
        {
            "provider": {
                "cornelis": {
                    "models": {
                        "developer-gemini-flash": {
                            "id": "developer-gemini-flash",
                            "cost": { "input": 0.5, "output": 3 }
                        }
                    }
                }
            }
        }
        """
        let pricing = PricingConfigLoader.parsePricing(fromJSONC: jsonc)
        #expect(pricing.count == 1)
        #expect(pricing[0].cacheReadPricePerMillion == nil)
    }

    @Test func skipsModelsWithoutUsableCost() {
        // "assistant" has cost: null and must be skipped; a model missing the
        // output price is also skipped.
        let jsonc = """
        {
            "provider": {
                "cornelis": {
                    "models": {
                        "assistant": { "id": "assistant", "cost": null },
                        "broken": { "id": "broken", "cost": { "input": 1 } },
                        "good": { "id": "good", "cost": { "input": 2, "output": 8 } }
                    }
                }
            }
        }
        """
        let pricing = PricingConfigLoader.parsePricing(fromJSONC: jsonc)
        #expect(pricing.count == 1)
        #expect(pricing[0].modelName == "good")
    }

    @Test func returnsEmptyWhenNoProviderNode() {
        let pricing = PricingConfigLoader.parsePricing(fromJSONC: #"{ "foo": 1 }"#)
        #expect(pricing.isEmpty)
    }

    @Test func parsesAcrossMultipleProviders() {
        let jsonc = """
        {
            "provider": {
                "cornelis": {
                    "models": {
                        "developer-opus": { "id": "developer-opus", "cost": { "input": 5, "output": 25 } }
                    }
                },
                "other": {
                    "models": {
                        "some-model": { "id": "some-model", "cost": { "input": 1, "output": 2 } }
                    }
                }
            }
        }
        """
        let pricing = PricingConfigLoader.parsePricing(fromJSONC: jsonc)
        #expect(pricing.count == 2)
        let names = Set(pricing.map { $0.modelName })
        #expect(names == ["developer-opus", "some-model"])
    }

    // MARK: - loadPricing (file resolution)

    @Test func loadPricingReadsExplicitFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = tempDir.appendingPathComponent("opencode.json").path
        let contents = """
        {
            // pricing config with a URL that must survive
            "provider": {
                "cornelis": {
                    "options": { "baseURL": "http://cn-ai-01.cornelisnetworks.com:50800/v1" },
                    "models": {
                        "developer-opus-extended": { "id": "developer-opus-extended", "cost": { "input": 5, "output": 25, "cache_read": 0.5 } }
                    }
                }
            }
        }
        """
        try contents.write(toFile: path, atomically: true, encoding: .utf8)

        let pricing = PricingConfigLoader.loadPricing(from: path)
        #expect(pricing.count == 1)
        #expect(pricing[0].modelName == "developer-opus-extended")
        #expect(pricing[0].cacheReadPricePerMillion == 0.5)
    }

    @Test func loadPricingReturnsEmptyForMissingFile() {
        let pricing = PricingConfigLoader.loadPricing(from: "/nonexistent/opencode.json")
        #expect(pricing.isEmpty)
    }

    // MARK: - mergePricing precedence

    @Test func mergeLetsConfigOverrideDefault() {
        let defaults = [
            ModelPricing(modelName: "developer-opus-extended", inputPricePerMillion: 99, outputPricePerMillion: 99),
            ModelPricing(modelName: "claude-opus-4-6", inputPricePerMillion: 5, outputPricePerMillion: 25)
        ]
        let overrides = [
            ModelPricing(modelName: "developer-opus-extended", inputPricePerMillion: 5, outputPricePerMillion: 25, cacheReadPricePerMillion: 0.5)
        ]
        let merged = CostEstimator.mergePricing(defaults: defaults, overrides: overrides)

        // Config wins on the shared key; the default-only key is retained.
        let lookup = Dictionary(uniqueKeysWithValues: merged.map { ($0.modelName.lowercased(), $0) })
        #expect(lookup["developer-opus-extended"]?.inputPricePerMillion == 5)
        #expect(lookup["developer-opus-extended"]?.cacheReadPricePerMillion == 0.5)
        #expect(lookup["claude-opus-4-6"]?.inputPricePerMillion == 5)
        #expect(merged.count == 2)
    }

    @Test func mergeAddsNewConfigModels() {
        let defaults = [
            ModelPricing(modelName: "claude-opus-4-6", inputPricePerMillion: 5, outputPricePerMillion: 25)
        ]
        let overrides = [
            ModelPricing(modelName: "brand-new-model", inputPricePerMillion: 1, outputPricePerMillion: 2)
        ]
        let merged = CostEstimator.mergePricing(defaults: defaults, overrides: overrides)
        #expect(merged.count == 2)
        #expect(merged.contains { $0.modelName == "brand-new-model" })
    }

    @Test func mergePreservesDefaultsWhenNoOverrides() {
        let defaults = [
            ModelPricing(modelName: "claude-opus-4-6", inputPricePerMillion: 5, outputPricePerMillion: 25)
        ]
        let merged = CostEstimator.mergePricing(defaults: defaults, overrides: [])
        #expect(merged.count == 1)
        #expect(merged[0].modelName == "claude-opus-4-6")
    }
}
