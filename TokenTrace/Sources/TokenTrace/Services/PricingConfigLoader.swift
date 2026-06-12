import Foundation

/// Loads model pricing dynamically from the OpenCode configuration file
/// (`opencode.json`) at runtime, rather than hardcoding prices in Swift.
///
/// Rationale: the LLM gateway at cn-ai-01 exposes model *names* via
/// `GET /v1/models` but no pricing endpoint (all pricing routes 404). The only
/// machine-readable price list on the machine is `provider.<name>.models[].cost`
/// inside `opencode.json` — the same config OpenCode itself uses to bill the
/// model aliases TokenTrace stores (e.g. "developer-opus-extended"). Reading
/// prices from there keeps them user-maintained and in lock-step with the
/// aliases that actually appear in our `usage_events.model` column.
///
/// The file is JSONC (JSON with `//` and `/* */` comments), so comments are
/// stripped before parsing. Parsing is best-effort: any failure returns an
/// empty result and the caller falls back to its built-in default table.
enum PricingConfigLoader {

    // MARK: - Public API

    /// Resolves and parses the OpenCode config, returning one `ModelPricing`
    /// per model that declares a `cost` block.
    ///
    /// - Parameter explicitPath: Override path (used by tests). When `nil`, the
    ///   standard config locations are searched in order.
    /// - Returns: Parsed pricing entries, or `[]` when the file is missing or
    ///   unparseable.
    static func loadPricing(from explicitPath: String? = nil) -> [ModelPricing] {
        guard let path = explicitPath ?? defaultConfigPath(),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return parsePricing(fromJSONC: raw)
    }

    /// Returns the first existing OpenCode config path, honoring
    /// `XDG_CONFIG_HOME` and falling back to `~/.config/opencode/`.
    static func defaultConfigPath() -> String? {
        var candidates: [String] = []

        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append((xdg as NSString).appendingPathComponent("opencode/opencode.json"))
            candidates.append((xdg as NSString).appendingPathComponent("opencode/opencode.jsonc"))
        }

        let home = NSHomeDirectory()
        candidates.append("\(home)/.config/opencode/opencode.json")
        candidates.append("\(home)/.config/opencode/opencode.jsonc")

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Parsing

    /// Parses pricing entries from a JSONC string (JSON allowing `//` and
    /// `/* */` comments). Returns `[]` on any structural failure.
    static func parsePricing(fromJSONC jsonc: String) -> [ModelPricing] {
        let cleaned = stripJSONComments(jsonc)
        guard let data = cleaned.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["provider"] as? [String: Any] else {
            return []
        }

        var result: [ModelPricing] = []

        // Iterate every provider so the loader is not hardcoded to "cornelis".
        for (_, providerValue) in providers {
            guard let provider = providerValue as? [String: Any],
                  let models = provider["models"] else {
                continue
            }

            // `models` is normally a dict keyed by model id, but tolerate an
            // array of model objects that each carry their own `id`.
            let modelEntries: [(String, [String: Any])] = normalizeModels(models)

            for (key, model) in modelEntries {
                // Prefer an explicit `id`; fall back to the dict key.
                let modelName = (model["id"] as? String) ?? key
                guard !modelName.isEmpty,
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"]) else {
                    // No usable cost block (e.g. "assistant" has cost: null) — skip.
                    continue
                }

                let cacheRead = doubleValue(cost["cache_read"])
                result.append(ModelPricing(
                    modelName: modelName,
                    inputPricePerMillion: input,
                    outputPricePerMillion: output,
                    cacheReadPricePerMillion: cacheRead
                ))
            }
        }

        return result
    }

    /// Normalizes the `models` node into `(key, modelObject)` pairs, accepting
    /// either a dict keyed by id or an array of model objects.
    private static func normalizeModels(_ models: Any) -> [(String, [String: Any])] {
        if let dict = models as? [String: Any] {
            return dict.compactMap { key, value in
                (value as? [String: Any]).map { (key, $0) }
            }
        }
        if let array = models as? [[String: Any]] {
            return array.map { ((($0["id"] as? String) ?? ""), $0) }
        }
        return []
    }

    /// Coerces a JSON number (Int, Double, or NSNumber) to `Double`. Returns
    /// `nil` for missing/`null`/non-numeric values. A JSON `null` deserializes
    /// to `NSNull`, which matches none of these cases and falls through to nil.
    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int:    return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    // MARK: - JSONC Comment Stripping

    /// Removes `//` line comments and `/* */` block comments from a JSONC
    /// string while preserving comment-like sequences that appear *inside*
    /// string literals (critical: URLs such as `http://host` must survive).
    static func stripJSONComments(_ input: String) -> String {
        enum State { case normal, string, lineComment, blockComment }

        var state: State = .normal
        var escaped = false
        var output = String()
        output.reserveCapacity(input.count)

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            switch state {
            case .normal:
                if c == "\"" {
                    state = .string
                    output.append(c)
                } else if c == "/" && next == "/" {
                    state = .lineComment
                    i += 2
                    continue
                } else if c == "/" && next == "*" {
                    state = .blockComment
                    i += 2
                    continue
                } else {
                    output.append(c)
                }

            case .string:
                output.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    state = .normal
                }

            case .lineComment:
                if c == "\n" {
                    state = .normal
                    output.append(c) // keep the newline so line numbers/JSON stay valid
                }

            case .blockComment:
                if c == "*" && next == "/" {
                    state = .normal
                    i += 2
                    continue
                }
            }

            i += 1
        }

        return output
    }
}
