import Foundation
import Testing
@testable import AIUsageCore

struct UsageHistoryTests {
    private func formatter(timeZone: String = "UTC") throws -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func event(_ timestamp: String, total: Int?, last: Int? = nil) throws -> String {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = ["total_tokens": total] }
        if let last {
            info["last_token_usage"] = ["total_tokens": last, "input_tokens": last, "output_tokens": 0]
        }
        let value: [String: Any] = [
            "timestamp": timestamp,
            "payload": ["type": "token_count", "info": info]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    @Test func crossMidnightSessionUsesEventDays() throws {
        let text = try [
            event("2026-11-22T23:59:00Z", total: 100, last: 100),
            event("2026-11-23T00:01:00.123Z", total: 300, last: 200)
        ].joined(separator: "\n")
        let buckets = CodexUsageLogParser.dailyBuckets(
            in: text, validKeys: ["2026-11-22", "2026-11-23"], formatter: try formatter()
        )
        #expect(buckets["2026-11-22"]?.tokens == 100)
        #expect(buckets["2026-11-23"]?.tokens == 200)
        #expect(buckets["2026-11-23"]?.requests == 1)
    }

    @Test func cumulativeOnlyEventsUseDeltasAndKeepOutOfRangeBaseline() throws {
        let text = try [
            event("2026-11-21T23:00:00Z", total: 100),
            event("2026-11-22T02:00:00Z", total: 300)
        ].joined(separator: "\n")
        let buckets = CodexUsageLogParser.dailyBuckets(in: text, validKeys: ["2026-11-22"], formatter: try formatter())
        #expect(buckets.count == 1)
        #expect(buckets["2026-11-22"]?.tokens == 200)
    }

    @Test func repeatedCumulativeEventDoesNotRepeatLastUsage() throws {
        let line = try event("2026-11-22T01:00:00Z", total: 100, last: 100)
        let buckets = CodexUsageLogParser.dailyBuckets(in: line + "\n" + line, validKeys: ["2026-11-22"], formatter: try formatter())
        #expect(buckets["2026-11-22"]?.tokens == 100)
        #expect(buckets["2026-11-22"]?.requests == 1)
    }

    @Test func timestampRespectsLocalDayAcrossUTCDateBoundary() throws {
        let line = try event("2026-11-22T17:00:00Z", total: 100)
        let buckets = CodexUsageLogParser.dailyBuckets(in: line, validKeys: ["2026-11-23"], formatter: try formatter(timeZone: "Asia/Shanghai"))
        #expect(buckets["2026-11-23"]?.tokens == 100)
    }

    @Test func missingOrMalformedTimestampIsNotGuessedFromFileDate() throws {
        let text = try [event("invalid", total: 100), event("2026-11-23T01:00:00Z", total: 300)].joined(separator: "\n")
        let buckets = CodexUsageLogParser.dailyBuckets(in: text, validKeys: ["2026-11-23"], formatter: try formatter())
        #expect(buckets["2026-11-23"]?.tokens == 200)
    }

    @Test func counterResetAndLastOnlyEventsMaintainBaseline() throws {
        let text = try [
            event("2026-11-23T01:00:00Z", total: 100, last: 100),
            event("2026-11-23T02:00:00Z", total: 30, last: 30),
            event("2026-11-23T03:00:00Z", total: nil, last: 20),
            event("2026-11-23T04:00:00Z", total: 70, last: 20)
        ].joined(separator: "\n")
        let buckets = CodexUsageLogParser.dailyBuckets(in: text, validKeys: ["2026-11-23"], formatter: try formatter())
        #expect(buckets["2026-11-23"]?.tokens == 170)
        #expect(buckets["2026-11-23"]?.requests == 4)
    }

    private func point(_ day: String, costs: [AIUsageCost]) -> AIUsageWidgetDailyPoint {
        AIUsageWidgetDailyPoint(dayKey: day, tokens: 100, requests: 1, costs: costs)
    }

    @Test func dollarsAndYuanArePreservedWithoutNumericMaximum() throws {
        let local = AIUsageCost(amount: 1, currency: "USD", source: .localEstimate)
        let balance = AIUsageCost(amount: 10, currency: "CNY", source: .balanceDelta)
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [local, balance])], preferredCurrency: "CNY")
        let result = try #require(series.first)
        #expect(result.cost == 10)
        #expect(result.selectedCost?.currencySymbol == "¥")
        #expect(result.selectedCost?.chartCurrencyPrefix == "¥")
        #expect(result.selectedCost?.source == .balanceDelta)
        #expect(result.costs == [local, balance])
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(AIUsageWidgetDailyPoint.self, from: encoded) == result)
    }

    @Test func sameCurrencyEstimateDoesNotOverrideBalanceObservation() {
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 20, currency: "USD", source: .localEstimate),
            AIUsageCost(amount: 1, currency: "USD", source: .balanceDelta)
        ])], preferredCurrency: "USD")
        #expect(series.first?.cost == 1)
        #expect(series.first?.costs.count == 2)
    }

    @Test func entireSeriesUsesOneCurrencyAndSourceIncludingEmptyDays() {
        let points = [
            point("2026-11-22", costs: [AIUsageCost(amount: 4, currency: "USD", source: .localEstimate)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 10, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-24", costs: [AIUsageCost(amount: 7, currency: "EUR", source: .balanceDelta)])
        ]
        let series = AIUsageCostSeries.select(points, preferredCurrency: "RMB")
        #expect(series.map(\.cost) == [0, 10, 0])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "CNY" && $0.selectedCost?.source == .balanceDelta })
    }

    @Test func localEstimateIsExplicitlyUSDWhenNoBalanceHistoryExists() {
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 1, currency: "USD", source: .localEstimate)
        ])], preferredCurrency: "CNY")
        #expect(series.first?.cost == 1)
        #expect(series.first?.selectedCost?.currencySymbol == "$")
        #expect(series.first?.selectedCost?.chartCurrencyPrefix == "≈$")
        #expect(series.first?.selectedCost?.source == .localEstimate)
    }

    @Test func legacyLedgerAmountWithoutCurrencyIsNotRelabeled() throws {
        let legacy = Data(#"{"tokens":12,"requests":2,"cost":10}"#.utf8)
        var entry = try JSONDecoder().decode(AIUsageLedgerEntry.self, from: legacy)
        #expect(entry.costs.isEmpty)
        #expect(entry.legacyUnattributedCost == 10)
        entry.addBalanceDelta(2, currency: "CNY")
        entry.addBalanceDelta(3, currency: "RMB")
        entry.addBalanceDelta(1, currency: "USD")
        #expect(entry.costs.map(\.amount) == [5, 1])
        #expect(entry.costs.map(\.currency) == ["CNY", "USD"])
        let restored = try JSONDecoder().decode(AIUsageLedgerEntry.self, from: JSONEncoder().encode(entry))
        #expect(restored.costs == entry.costs)
        #expect(restored.legacyUnattributedCost == 10)
    }

    @Test func legacyWidgetAmountWithoutCurrencyIsNotShownAsDollars() throws {
        let legacy = Data(#"{"dayKey":"2026-11-23","tokens":100,"cost":10,"requests":1}"#.utf8)
        let point = try JSONDecoder().decode(AIUsageWidgetDailyPoint.self, from: legacy)
        #expect(point.tokens == 100)
        #expect(point.cost == 0)
        #expect(point.selectedCost == nil)
    }
}
