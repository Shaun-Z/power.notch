//
//  CurrencyRates.swift
//  AIUsageCore
//
//  A 30-day cost chart plots one series per provider, but a provider's balance history can span
//  more than one currency: a region switch, or a wallet that moved from CNY to USD. Dropping the
//  days of the other currency is worse than an approximate conversion, so the chart converts —
//  but only when it has to.
//
//  Rates are pivoted on USD: `perUSD["CNY"] = 6.68` means one US dollar buys 6.68 yuan. They come
//  from exchangerate-api's free daily feed (no key) and are cached; `fallback` is only the
//  first-run/offline table, so a converted chart is an estimate, and it says so with "≈" where the
//  numbers come from local estimates alone.
//

import Foundation

struct AIUsageCurrencyRates: Codable, Equatable, Sendable {
    /// Units of each currency per one US dollar, always including `"USD": 1`.
    var perUSD: [String: Double]
    var updatedAt: Date?

    init(perUSD: [String: Double], updatedAt: Date? = nil) {
        var normalized: [String: Double] = [:]
        for (code, value) in perUSD where value > 0 && value.isFinite {
            normalized[code.uppercased()] = value
        }
        normalized["USD"] = 1
        self.perUSD = normalized
        self.updatedAt = updatedAt
    }

    /// Rates older than a week are refreshed; the chart keeps using them until the feed answers.
    static let maxAge: TimeInterval = 7 * 86_400

    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > Self.maxAge
    }

    /// Approximate rates, used only until the daily feed has answered once.
    static let fallback = AIUsageCurrencyRates(perUSD: [
        "USD": 1,
        "CNY": 7.10,
        "EUR": 0.92,
        "GBP": 0.79,
        "JPY": 157,
        "KRW": 1_380,
        "HKD": 7.80,
        "TWD": 32,
        "SGD": 1.34,
        "INR": 84,
    ])

    /// Parses the feed document (`{"base_code":"USD","rates":{...}}`). Anything that is not a
    /// positive finite number is dropped rather than guessed, and a document that names no rate
    /// besides USD is not a rate table.
    static func fromFeed(_ json: [String: Any], updatedAt: Date = Date()) -> AIUsageCurrencyRates? {
        guard let rates = json["rates"] as? [String: Any] else { return nil }
        var perUSD: [String: Double] = [:]
        for (code, raw) in rates {
            guard let value = number(raw), value > 0 else { continue }
            perUSD[code.uppercased()] = value
        }
        guard perUSD.count > 1 else { return nil }
        return AIUsageCurrencyRates(perUSD: perUSD, updatedAt: updatedAt)
    }

    /// `amount` expressed in `target`, or `nil` when either side has no known rate — a missing
    /// rate must leave a gap, never a made-up number.
    func convert(_ amount: Double, from currency: String, to target: String) -> Double? {
        let source = AIUsageCost.normalizedCurrency(currency)
        let destination = AIUsageCost.normalizedCurrency(target)
        if source == destination { return amount }
        guard let sourceRate = perUSD[source], let destinationRate = perUSD[destination] else {
            return nil
        }
        return amount / sourceRate * destinationRate
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
