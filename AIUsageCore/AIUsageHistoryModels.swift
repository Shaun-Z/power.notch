import Foundation

enum AIUsageCostSource: String, Codable, Sendable {
    case localEstimate
    case balanceDelta
}

struct AIUsageCost: Codable, Sendable, Equatable {
    var amount: Double
    let currency: String
    let source: AIUsageCostSource

    init(amount: Double, currency: String, source: AIUsageCostSource) {
        self.amount = amount.isFinite ? max(0, amount) : 0
        self.currency = Self.normalizedCurrency(currency)
        self.source = source
    }

    static func normalizedCurrency(_ currency: String) -> String {
        switch currency.uppercased() {
        case "RMB", "¥": return "CNY"
        case "$": return "USD"
        case "€": return "EUR"
        case "£": return "GBP"
        default: return currency.uppercased()
        }
    }

    var currencySymbol: String {
        switch currency {
        case "USD": return "$"
        case "CNY": return "¥"
        case "JPY": return "JP¥"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return currency + " "
        }
    }

    var chartCurrencyPrefix: String {
        source == .localEstimate ? "≈" + currencySymbol : currencySymbol
    }
}

struct AIUsageDailyBucket: Sendable {
    var tokens: Int64 = 0
    // Local log scanners report USD API-equivalent estimates only.
    var cost: Double = 0
    var requests: Int = 0
}

struct AIUsageLedgerEntry: Codable, Sendable {
    var tokens: Int64 = 0
    var costs: [AIUsageCost] = []
    var requests: Int = 0
    // Preserve the old number on disk, but never display it with a guessed currency.
    var legacyUnattributedCost: Double?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tokens, costs, requests
        case legacyUnattributedCost = "cost"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try values.decodeIfPresent(Int64.self, forKey: .tokens) ?? 0
        costs = try values.decodeIfPresent([AIUsageCost].self, forKey: .costs) ?? []
        requests = try values.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        legacyUnattributedCost = try values.decodeIfPresent(Double.self, forKey: .legacyUnattributedCost)
        // Legacy `cost` had no currency or source. It cannot be safely recovered.
    }

    mutating func addBalanceDelta(_ amount: Double, currency: String) {
        guard amount.isFinite, amount > 0 else { return }
        let currency = AIUsageCost.normalizedCurrency(currency)
        if let index = costs.firstIndex(where: { $0.currency == currency && $0.source == .balanceDelta }) {
            costs[index].amount += amount
        } else {
            costs.append(AIUsageCost(amount: amount, currency: currency, source: .balanceDelta))
        }
    }
}

struct AIUsageWidgetDailyPoint: Codable, Identifiable, Sendable, Equatable {
    let dayKey: String
    let tokens: Int64
    let requests: Int
    let costs: [AIUsageCost]
    let selectedCost: AIUsageCost?

    var id: String { dayKey }
    var cost: Double { selectedCost?.amount ?? 0 }

    init(dayKey: String, tokens: Int64, requests: Int, costs: [AIUsageCost], selectedCost: AIUsageCost? = nil) {
        self.dayKey = dayKey
        self.tokens = tokens
        self.requests = requests
        self.costs = costs
        self.selectedCost = selectedCost
    }

    // Convenience for zero scaffolds and explicitly USD sample data in widget previews.
    init(dayKey: String, tokens: Int64, cost: Double, requests: Int) {
        let estimate = AIUsageCost(amount: cost, currency: "USD", source: .localEstimate)
        self.init(dayKey: dayKey, tokens: tokens, requests: requests, costs: [estimate], selectedCost: estimate)
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, tokens, cost, requests, costs, selectedCost
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try values.decode(String.self, forKey: .dayKey)
        tokens = try values.decode(Int64.self, forKey: .tokens)
        requests = try values.decode(Int.self, forKey: .requests)
        costs = try values.decodeIfPresent([AIUsageCost].self, forKey: .costs) ?? []
        selectedCost = try values.decodeIfPresent(AIUsageCost.self, forKey: .selectedCost)
        // Ignore legacy amounts of unknown denomination until the app refreshes the history.
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dayKey, forKey: .dayKey)
        try values.encode(tokens, forKey: .tokens)
        try values.encode(requests, forKey: .requests)
        try values.encode(costs, forKey: .costs)
        try values.encodeIfPresent(selectedCost, forKey: .selectedCost)
        // Keep older widget readers compatible with the selected, consistently denominated series.
        try values.encode(cost, forKey: .cost)
    }

    var shortDateLabel: String {
        let parts = dayKey.split(separator: "-")
        if parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) {
            return "\(month)/\(day)"
        }
        return dayKey
    }
}

enum AIUsageCostSeries {
    /// Use one source and currency for the entire chart. Never add, compare, or convert
    /// balance-derived spend and API-equivalent estimates, even in the same currency.
    static func select(_ points: [AIUsageWidgetDailyPoint], preferredCurrency: String?) -> [AIUsageWidgetDailyPoint] {
        let costs = points.flatMap(\.costs).filter { $0.amount > 0 }
        let preferred = preferredCurrency.map(AIUsageCost.normalizedCurrency)
        let balanceCosts = costs.filter { $0.source == .balanceDelta }.sorted { $0.currency < $1.currency }
        let selection = balanceCosts.first(where: { $0.currency == preferred })
            ?? balanceCosts.first
            ?? costs.first(where: { $0.source == .localEstimate && $0.currency == "USD" })

        return points.map { point in
            let selected = selection.map { selection in
                AIUsageCost(
                    amount: point.costs.filter { $0.currency == selection.currency && $0.source == selection.source }
                        .reduce(0) { $0 + $1.amount },
                    currency: selection.currency,
                    source: selection.source
                )
            }
            return AIUsageWidgetDailyPoint(
                dayKey: point.dayKey, tokens: point.tokens, requests: point.requests,
                costs: point.costs, selectedCost: selected
            )
        }
    }
}
