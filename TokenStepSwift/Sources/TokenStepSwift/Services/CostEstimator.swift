import Foundation

struct EstimatedCost: Codable {
    var usd: Double
    var cny: Double
    var nativeCurrency: String
    var nativeAmount: Double
}

private struct ModelRateCard: Codable {
    var currency: String?
    var inputPer1M: Double?
    var outputPer1M: Double?
    var cacheReadPer1M: Double?
    var cacheCreationPer1M: Double?
    var totalPer1M: Double?

    enum CodingKeys: String, CodingKey {
        case currency
        case inputPer1M = "input_per_1m"
        case outputPer1M = "output_per_1m"
        case cacheReadPer1M = "cache_read_per_1m"
        case cacheCreationPer1M = "cache_creation_per_1m"
        case totalPer1M = "total_per_1m"
    }
}

private struct PricingConfig: Codable {
    var exchangeRate: ExchangeRate
    var models: [String: ModelRateCard]

    struct ExchangeRate: Codable {
        var usdToCny: Double

        enum CodingKeys: String, CodingKey {
            case usdToCny = "usd_to_cny"
        }
    }

    enum CodingKeys: String, CodingKey {
        case exchangeRate = "exchange_rate"
        case models
    }
}

enum TokenStepCostEstimator {
    private static var cachedRates: [String: ModelRateCard]?
    private static var cachedExchangeRate: Double = 7.25

    static var exchangeRate: Double {
        _ = loadRates()
        return cachedExchangeRate
    }

    static func cost(for model: String, usage: TokenUsageCounts) -> EstimatedCost {
        let rates = loadRates()
        let exchangeRate = loadExchangeRate()
        let key = model.lowercased().trimmingCharacters(in: .whitespaces)
        let card = rates[key] ?? rates[modelKeyAlias(for: key)]

        let nativeAmount: Double
        let currency: String
        if let card = card {
            currency = (card.currency ?? "USD").uppercased()
            if let input = card.inputPer1M,
               let output = card.outputPer1M {
                let cacheRead = card.cacheReadPer1M ?? input
                let cacheCreation = card.cacheCreationPer1M ?? input
                nativeAmount = (
                    Double(usage.inputTokens) * input
                    + Double(usage.outputTokens) * output
                    + Double(usage.cacheReadInputTokens) * cacheRead
                    + Double(usage.cacheCreationInputTokens) * cacheCreation
                ) / 1_000_000.0
            } else if let total = card.totalPer1M {
                nativeAmount = Double(usage.totalTokens) * total / 1_000_000.0
            } else {
                nativeAmount = fallbackCost(model: model, usage: usage)
                return EstimatedCost(
                    usd: nativeAmount,
                    cny: nativeAmount * exchangeRate,
                    nativeCurrency: "USD",
                    nativeAmount: nativeAmount
                )
            }
        } else {
            currency = "USD"
            nativeAmount = fallbackCost(model: model, usage: usage)
        }

        let usd: Double
        let cny: Double
        if currency == "CNY" {
            usd = nativeAmount / exchangeRate
            cny = nativeAmount
        } else {
            usd = nativeAmount
            cny = nativeAmount * exchangeRate
        }
        return EstimatedCost(
            usd: usd,
            cny: cny,
            nativeCurrency: currency,
            nativeAmount: nativeAmount
        )
    }

    private static func fallbackCost(model: String, usage: TokenUsageCounts) -> Double {
        if model.lowercased().contains("claude-opus") {
            return Double(usage.totalTokens) / 1_000_000.0 * 30.0
        }
        if model.lowercased().contains("claude-sonnet") || model.lowercased().contains("claude") {
            return Double(usage.totalTokens) / 1_000_000.0 * 6.0
        }
        return Double(usage.totalTokens) / 1_000_000.0 * 1.0
    }

    private static func modelKeyAlias(for key: String) -> String {
        if key.hasPrefix("kimi") { return "kimi" }
        if key.hasPrefix("deepseek") { return "deepseek" }
        if key.hasPrefix("glm") { return "glm" }
        if key.hasPrefix("gpt") { return "gpt" }
        if key.hasPrefix("claude") { return "claude" }
        return key
    }

    private static func loadRates() -> [String: ModelRateCard] {
        if let cached = cachedRates { return cached }
        var rates = defaultRates()
        if let override = loadOverrideConfig() {
            for (key, card) in override.models {
                rates[key.lowercased()] = card
            }
            cachedExchangeRate = override.exchangeRate.usdToCny
        }
        cachedRates = rates
        return rates
    }

    private static func loadExchangeRate() -> Double {
        _ = loadRates()
        return cachedExchangeRate
    }

    private static func loadOverrideConfig() -> PricingConfig? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home
            .appendingPathComponent("Library/Application Support/TokenStep/config/pricing.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(PricingConfig.self, from: data)
    }

    private static func defaultRates() -> [String: ModelRateCard] {
        let cnyRates = [
            "kimi for coding": ModelRateCard(
                currency: "CNY",
                inputPer1M: 6.9,
                outputPer1M: 29.0,
                cacheReadPer1M: 1.16,
                cacheCreationPer1M: 6.9,
                totalPer1M: nil
            ),
            "kimi 2.6": ModelRateCard(
                currency: "CNY",
                inputPer1M: 6.9,
                outputPer1M: 29.0,
                cacheReadPer1M: 1.16,
                cacheCreationPer1M: 6.9,
                totalPer1M: nil
            ),
            "kimi 2.7": ModelRateCard(
                currency: "CNY",
                inputPer1M: 6.9,
                outputPer1M: 29.0,
                cacheReadPer1M: 1.16,
                cacheCreationPer1M: 6.9,
                totalPer1M: nil
            ),
            "kimi": ModelRateCard(
                currency: "CNY",
                inputPer1M: 6.0,
                outputPer1M: 25.0,
                cacheReadPer1M: 1.0,
                cacheCreationPer1M: 6.0,
                totalPer1M: nil
            )
        ]

        let usdRates = [
            "deepseek v4 pro": ModelRateCard(
                currency: "USD",
                inputPer1M: 0.435,
                outputPer1M: 0.87,
                cacheReadPer1M: 0.003625,
                cacheCreationPer1M: 0.435,
                totalPer1M: nil
            ),
            "deepseek v4 flash": ModelRateCard(
                currency: "USD",
                inputPer1M: 0.14,
                outputPer1M: 0.28,
                cacheReadPer1M: 0.0028,
                cacheCreationPer1M: 0.14,
                totalPer1M: nil
            ),
            "deepseek": ModelRateCard(
                currency: "USD",
                inputPer1M: 0.5,
                outputPer1M: 1.0,
                cacheReadPer1M: 0.05,
                cacheCreationPer1M: 0.5,
                totalPer1M: nil
            ),
            "glm-5.2": ModelRateCard(
                currency: "USD",
                inputPer1M: 1.4,
                outputPer1M: 4.4,
                cacheReadPer1M: 0.26,
                cacheCreationPer1M: 1.4,
                totalPer1M: nil
            ),
            "glm-5.1": ModelRateCard(
                currency: "USD",
                inputPer1M: 1.4,
                outputPer1M: 4.4,
                cacheReadPer1M: 0.26,
                cacheCreationPer1M: 1.4,
                totalPer1M: nil
            ),
            "glm-5": ModelRateCard(
                currency: "USD",
                inputPer1M: 1.0,
                outputPer1M: 3.2,
                cacheReadPer1M: 0.2,
                cacheCreationPer1M: 1.0,
                totalPer1M: nil
            ),
            "glm": ModelRateCard(
                currency: "USD",
                inputPer1M: 0.5,
                outputPer1M: 1.5,
                cacheReadPer1M: 0.1,
                cacheCreationPer1M: 0.5,
                totalPer1M: nil
            ),
            "gpt-5.5": ModelRateCard(
                currency: "USD",
                inputPer1M: 5.0,
                outputPer1M: 30.0,
                cacheReadPer1M: 0.5,
                cacheCreationPer1M: 5.0,
                totalPer1M: nil
            ),
            "gpt-5.4": ModelRateCard(
                currency: "USD",
                inputPer1M: 2.5,
                outputPer1M: 15.0,
                cacheReadPer1M: 0.25,
                cacheCreationPer1M: 2.5,
                totalPer1M: nil
            ),
            "gpt-5": ModelRateCard(
                currency: "USD",
                inputPer1M: 1.25,
                outputPer1M: 10.0,
                cacheReadPer1M: 0.125,
                cacheCreationPer1M: 1.25,
                totalPer1M: nil
            ),
            "gpt-5-codex": ModelRateCard(
                currency: "USD",
                inputPer1M: 2.5,
                outputPer1M: 15.0,
                cacheReadPer1M: 0.25,
                cacheCreationPer1M: 2.5,
                totalPer1M: nil
            ),
            "codex auto-review": ModelRateCard(
                currency: "USD",
                inputPer1M: 2.5,
                outputPer1M: 15.0,
                cacheReadPer1M: 0.25,
                cacheCreationPer1M: 2.5,
                totalPer1M: nil
            ),
            "claude-opus": ModelRateCard(
                currency: "USD",
                inputPer1M: 15.0,
                outputPer1M: 75.0,
                cacheReadPer1M: 1.5,
                cacheCreationPer1M: 18.75,
                totalPer1M: nil
            ),
            "claude-sonnet": ModelRateCard(
                currency: "USD",
                inputPer1M: 3.0,
                outputPer1M: 15.0,
                cacheReadPer1M: 0.3,
                cacheCreationPer1M: 3.75,
                totalPer1M: nil
            ),
            "claude": ModelRateCard(
                currency: "USD",
                inputPer1M: 3.0,
                outputPer1M: 15.0,
                cacheReadPer1M: 0.3,
                cacheCreationPer1M: 3.75,
                totalPer1M: nil
            )
        ]

        var combined = cnyRates
        for (key, card) in usdRates {
            combined[key] = card
        }
        return combined
    }
}
