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

    @Test func walletMovementWinsOverTheEstimateOnTheSameDay() throws {
        // Money that actually left the wallet beats an API-equivalent estimate of the same day.
        let local = AIUsageCost(amount: 1, currency: "USD", source: .localEstimate)
        let balance = AIUsageCost(amount: 10, currency: "CNY", source: .balanceDelta)
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [local, balance])], preferredCurrency: "CNY")
        let result = try #require(series.first)
        #expect(result.cost == 10)
        #expect(result.selectedCost?.currencySymbol == "¥")
        #expect(result.selectedCost?.chartCurrencyPrefix == "¥")
        #expect(result.selectedCost?.source == .balanceDelta)
        #expect(result.costs.count == 2)
        #expect(result.costs == [local, balance])
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(AIUsageWidgetDailyPoint.self, from: encoded) == result)
    }

    @Test func aSampledDropIsPreferredToTheEstimateForTheSampledDay() {
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 20, currency: "USD", source: .localEstimate),
            AIUsageCost(amount: 1, currency: "USD", source: .balanceDelta)
        ])], preferredCurrency: "USD")
        #expect(series.first?.cost == 1)
        #expect(series.first?.selectedCost?.source == .balanceDelta)
        #expect(series.first?.costs.count == 2)
    }

    @Test func mixedCurrenciesAreUnifiedInUSDWhenOneIsUSD() {
        let points = [
            point("2026-11-22", costs: [AIUsageCost(amount: 4, currency: "USD", source: .localEstimate)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 10, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-24", costs: [AIUsageCost(amount: 7, currency: "EUR", source: .balanceDelta)])
        ]
        // No wallet: a mixed history without USD stays on one of its currencies as reported.
        // No wallet, mixed currencies with USD in the set: every bucket converts into USD, and a
        // bucket keeps its own source (estimate where there is one, money where there is not).
        let series = AIUsageCostSeries.select(points, preferredCurrency: nil)
        #expect(series.map(\.selectedCost?.currency) == ["USD", "USD", "USD"])
        #expect(series.map(\.selectedCost?.source) == [.localEstimate, .balanceDelta, .balanceDelta])
        #expect(abs(series[0].cost - 4) < 0.0001)
        #expect(abs(series[1].cost - 10 / 7.10) < 0.0001)
        #expect(abs(series[2].cost - 7 / 0.92) < 0.0001)
    }

    @Test func localEstimateIsExplicitlyUSDWhenNoBalanceHistoryExists() {
        // A provider with no wallet at all (Codex credits, Antigravity tokens) charts its local
        // estimates in the currency they are computed in.
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 1, currency: "USD", source: .localEstimate)
        ])], preferredCurrency: nil)
        #expect(series.first?.cost == 1)
        #expect(series.first?.selectedCost?.currencySymbol == "$")
        #expect(series.first?.selectedCost?.chartCurrencyPrefix == "≈$")
        #expect(series.first?.selectedCost?.source == .localEstimate)
    }

    @Test func creditAllowanceDoesNotDisplaceTheMoneySeries() {
        // A subscription's credit allowance is quota, not spend: while the provider still reports
        // an API-equivalent estimate, the cost chart stays in dollars.
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 0.42, currency: "USD", source: .localEstimate),
            AIUsageCost(amount: 300, currency: "CREDITS", source: .balanceDelta)
        ])], preferredCurrency: nil)
        #expect(series.first?.selectedCost?.currency == "USD")
        #expect(series.first?.cost == 0.42)
    }

    @Test func creditAllowanceNeverBecomesMoneyWhenMoneyExists() {
        // The allowance and the credit wallet are quota; the money bucket plots the money.
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 0.42, currency: "USD", source: .localEstimate),
            AIUsageCost(amount: 300, currency: "CREDITS", source: .balanceDelta),
            AIUsageCost(amount: 12, currency: "CNY", source: .balanceDelta)
        ])], preferredCurrency: nil)
        #expect(series.first?.selectedCost?.currency == "USD")
        #expect(series.first?.selectedCost?.source == .balanceDelta)
        #expect(abs((series.first?.cost ?? 0) - 12 / 7.10) < 0.0001)
    }

    @Test func preferredCreditCurrencyDoesNotOverrideMoney() {
        // Codex pins its credit allowance, so the preferred currency is CREDITS — the chart still
        // plots the money series when there is one.
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 0.42, currency: "USD", source: .localEstimate),
            AIUsageCost(amount: 300, currency: "CREDITS", source: .balanceDelta)
        ])], preferredCurrency: "CREDITS")
        #expect(series.first?.cost == 0.42)
        #expect(series.first?.selectedCost?.source == .localEstimate)
    }

    @Test func singleCurrencyHistoryIsNeverConverted() throws {
        // One currency: plot it as reported, whatever USD would have cost.
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        let series = AIUsageCostSeries.select([
            point("2026-11-22", costs: [AIUsageCost(amount: 7.1, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 14.2, currency: "CNY", source: .balanceDelta)])
        ], preferredCurrency: "CNY", rates: rates)
        #expect(series.map(\.cost) == [7.1, 14.2])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "CNY" })
        let encoded = try JSONEncoder().encode(try #require(series.first))
        #expect(try JSONDecoder().decode(AIUsageWidgetDailyPoint.self, from: encoded).cost == 7.1)
    }

    @Test func mixedCurrencyHistoryContainingUSDIsUnifiedInUSD() {
        // A wallet that moved from CNY to USD: both days survive, the older one converted.
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        let series = AIUsageCostSeries.select([
            point("2026-11-22", costs: [AIUsageCost(amount: 7.1, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 2, currency: "USD", source: .balanceDelta)])
        ], preferredCurrency: nil, rates: rates)
        #expect(series.map(\.cost) == [1, 2])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "USD" && $0.selectedCost?.source == .balanceDelta })
        #expect(series.first?.selectedCost?.currencySymbol == "$")
    }

    @Test func mixedCurrencyHistoryWithoutUSDKeepsOneOfThemAsReported() {
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1, "EUR": 0.92])
        let series = AIUsageCostSeries.select([
            point("2026-11-22", costs: [AIUsageCost(amount: 7.1, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 3, currency: "EUR", source: .balanceDelta)])
        ], preferredCurrency: nil, rates: rates)
        // Mixed without USD and no wallet: the first currency in order wins, nothing is converted.
        #expect(series.map(\.cost) == [7.1, 0])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "CNY" })
    }

    @Test func walletCurrencyDecidesTheAxisEvenWhenOnlyEstimatesExist() {
        // MiMo bills in CNY but its 30-day history currently holds only USD API-equivalent
        // estimates, so the estimate is converted into the wallet the account is billed in.
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 2, currency: "USD", source: .localEstimate)
        ])], preferredCurrency: "CNY", rates: rates)
        #expect(series.first?.selectedCost?.currency == "CNY")
        #expect(series.first?.cost == 14.2)
        #expect(series.first?.selectedCost?.chartCurrencyPrefix == "≈¥")
    }

    @Test func usageLogFillsTheDaysTheWalletDidNotMove() {
        // DeepSeek: a CNY wallet drop on one day, a USD usage estimate on another. Both survive,
        // so the line has no holes, and the axis stays the wallet's yuan.
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        let series = AIUsageCostSeries.select([
            point("2026-11-25", costs: [AIUsageCost(amount: 0.87, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-26", costs: [AIUsageCost(amount: 0.34, currency: "USD", source: .localEstimate)])
        ], preferredCurrency: "CNY", rates: rates)
        #expect(abs(series[0].cost - 0.87) < 0.0001)
        #expect(abs(series[1].cost - 2.414) < 0.001)
        #expect(series.map(\.selectedCost?.source) == [.balanceDelta, .localEstimate])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "CNY" })
        #expect(series.first?.selectedCost?.currencySymbol == "¥")
    }

    @Test func walletCurrencyConvertsADifferentCurrencySpend() {
        // A wallet that moved to USD still charts the older CNY days, converted.
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        let series = AIUsageCostSeries.select([
            point("2026-11-22", costs: [AIUsageCost(amount: 7.1, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 2, currency: "USD", source: .balanceDelta)])
        ], preferredCurrency: "USD", rates: rates)
        #expect(series.map(\.cost) == [1, 2])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "USD" })
    }

    @Test func creditAllowanceIsNeverConvertedIntoTheWalletCurrency() {
        // An allowance measured in credits is a quota with no exchange rate; a CNY wallet must
        // not pretend to know what a credit is worth.
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 300, currency: "CREDITS", source: .balanceDelta)
        ])], preferredCurrency: "CNY")
        #expect(series.first?.selectedCost?.currency == "CREDITS")
        #expect(series.first?.cost == 300)
    }

    @Test func missingRateLeavesAGapInsteadOfAGuess() {
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1])
        let series = AIUsageCostSeries.select([
            point("2026-11-22", costs: [AIUsageCost(amount: 7.1, currency: "CNY", source: .balanceDelta)]),
            point("2026-11-23", costs: [AIUsageCost(amount: 2, currency: "USD", source: .balanceDelta)])
        ], preferredCurrency: nil, rates: rates)
        #expect(series.map(\.cost) == [0, 2])
        #expect(series.allSatisfy { $0.selectedCost?.currency == "USD" })
    }

    @Test func currencyRatesConvertAcrossSymbolAliases() {
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        #expect(rates.convert(7.1, from: "CNY", to: "USD") == 1)
        #expect(rates.convert(7.1, from: "RMB", to: "USD") == 1)
        #expect(rates.convert(7.1, from: "¥", to: "USD") == 1)
        #expect(rates.convert(1, from: "USD", to: "USD") == 1)
        #expect(rates.convert(1, from: "GBP", to: "USD") == nil)
    }

    @Test func currencyRatesRejectANonRateTable() {
        #expect(AIUsageCurrencyRates.fromFeed([:]) == nil)
        #expect(AIUsageCurrencyRates.fromFeed(["rates": ["USD": 1]]) == nil)
        #expect(AIUsageCurrencyRates.fromFeed(["rates": ["USD": 1, "CNY": "n/a"]]) == nil)
        let parsed = AIUsageCurrencyRates.fromFeed(
            ["base_code": "USD", "rates": ["USD": 1, "CNY": 7.1, "EUR": -2, "GBP": "0.79"]],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(parsed?.perUSD == ["USD": 1, "CNY": 7.1, "GBP": 0.79])
        #expect(parsed?.isStale == true)
        #expect(AIUsageCurrencyRates.fallback.perUSD["USD"] == 1)
    }

    @Test func creditAllowanceChartsAsUnitsNotACurrencyCode() {
        // With nothing else to plot, the allowance is the series and the header reads "cr 300",
        // not "CREDITS 300".
        let series = AIUsageCostSeries.select([point("2026-11-23", costs: [
            AIUsageCost(amount: 300, currency: "CREDITS", source: .balanceDelta)
        ])], preferredCurrency: nil)
        #expect(series.first?.selectedCost?.currency == "CREDITS")
        #expect(series.first?.selectedCost?.chartCurrencyPrefix == "cr ")
        #expect(AIUsageCost(amount: 1, currency: "TOKENS", source: .balanceDelta).currencySymbol == "tok ")
    }

    @Test func legacyLedgerAmountIsAttributedWhenTheProviderHasOneCurrency() throws {
        // MiMo and DeepSeek recorded balance deltas before the ledger carried a currency. A
        // provider whose deltas all share one currency can have those days back.
        let legacy = Data(#"{"tokens":0,"requests":1,"cost":0.87}"#.utf8)
        var entry = try JSONDecoder().decode(AIUsageLedgerEntry.self, from: legacy)
        #expect(entry.costs.isEmpty)
        #expect(entry.attributedCosts(legacyCurrency: "CNY").map(\.amount) == [0.87])
        #expect(entry.attributedCosts(legacyCurrency: "CNY").map(\.currency) == ["CNY"])
        #expect(entry.attributedCosts(legacyCurrency: "CNY").map(\.source) == [.balanceDelta])
        #expect(entry.attributedCosts(legacyCurrency: nil).isEmpty)
        #expect(entry.attributedCosts(legacyCurrency: "  ").isEmpty)

        // A day that already carries typed costs is left exactly as recorded.
        entry.addBalanceDelta(2, currency: "CNY")
        #expect(entry.attributedCosts(legacyCurrency: "USD").map(\.amount) == [2])
        #expect(entry.attributedCosts(legacyCurrency: "USD").map(\.currency) == ["CNY"])
    }

    @Test func attributedLegacySpendChartsInTheWalletCurrency() throws {
        let legacy = Data(#"{"tokens":0,"requests":1,"cost":2.7}"#.utf8)
        let entry = try JSONDecoder().decode(AIUsageLedgerEntry.self, from: legacy)
        let rates = AIUsageCurrencyRates(perUSD: ["USD": 1, "CNY": 7.1])
        let series = AIUsageCostSeries.select([
            point("2026-11-24", costs: entry.attributedCosts(legacyCurrency: "CNY"))
        ], preferredCurrency: "CNY", rates: rates)
        #expect(series.first?.cost == 2.7)
        #expect(series.first?.selectedCost?.currencySymbol == "¥")
        #expect(series.first?.selectedCost?.source == .balanceDelta)
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

/// The trend card offers a 24-hour window next to the 7- and 30-day ones, so the bucket keys the
/// collector fills have to line up with the labels the chart draws.
struct TrendWindowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_795_608_000) // 2026-11-25T12:00:00Z
    }

    @Test func dayKeysEndTodayAndCoverTheWindow() {
        let keys = AIUsageTrendWindow.dayKeys(days: 30, now: now, calendar: calendar)
        #expect(keys.count == 30)
        #expect(keys.last == "2026-11-25")
        #expect(keys.first == "2026-10-27")
        #expect(Set(keys).count == 30)
    }

    @Test func hourKeysEndAtTheCurrentHour() {
        let keys = AIUsageTrendWindow.hourKeys(hours: 24, now: now, calendar: calendar)
        #expect(keys.count == 24)
        #expect(keys.last == "2026-11-25T12")
        #expect(keys.first == "2026-11-24T13")
        #expect(Set(keys).count == 24)
        #expect(keys.allSatisfy { $0.contains("T") })
    }

    @Test func hourBucketsLabelAsAClockTimeNotADate() {
        let point = AIUsageWidgetDailyPoint(dayKey: "2026-11-25T14", tokens: 1, requests: 1, costs: [])
        #expect(point.shortDateLabel == "14:00")
        let day = AIUsageWidgetDailyPoint(dayKey: "2026-11-25", tokens: 1, requests: 1, costs: [])
        #expect(day.shortDateLabel == "11/25")
    }

    @Test func payloadCarriesTheHourlyWindowAndStillReadsAnOlderDocument() throws {
        let hourly = (0..<24).map { offset in
            AIUsageWidgetDailyPoint(
                dayKey: AIUsageTrendWindow.hourKeys(hours: 24, now: now, calendar: calendar)[offset],
                tokens: 10,
                requests: 1,
                costs: [AIUsageCost(amount: 0.5, currency: "USD", source: .localEstimate)]
            )
        }
        var page = AIUsageWidgetPayload.sample.providers.first!
        page = AIUsageWidgetProviderPage(
            id: page.id,
            displayName: page.displayName,
            shortName: page.shortName,
            iconAssetName: page.iconAssetName,
            symbolName: page.symbolName,
            accentRed: page.accentRed,
            accentGreen: page.accentGreen,
            accentBlue: page.accentBlue,
            innerRed: page.innerRed,
            innerGreen: page.innerGreen,
            innerBlue: page.innerBlue,
            planName: page.planName,
            accountLabel: page.accountLabel,
            sourceLabel: page.sourceLabel,
            statusNote: page.statusNote,
            errorMessage: page.errorMessage,
            updatedAt: page.updatedAt,
            ringGroups: page.ringGroups,
            balance: page.balance,
            dailyHistory: page.dailyHistory,
            hourlyHistory: hourly,
            costCurrencySymbol: page.costCurrencySymbol
        )
        let encoded = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(AIUsageWidgetProviderPage.self, from: encoded)
        #expect(decoded.hourlyHistory == hourly)
        #expect(decoded.hourlyHistory.first?.shortDateLabel == "13:00")

        // A payload written before the hourly window existed must still decode.
        let legacy = Data(#"{"id":"codex","displayName":"Codex","shortName":"Codex","iconAssetName":"i","symbolName":"s","accentRed":0,"accentGreen":0,"accentBlue":0,"innerRed":0,"innerGreen":0,"innerBlue":0,"ringGroups":[],"dailyHistory":[]}"#.utf8)
        let legacyPage = try JSONDecoder().decode(AIUsageWidgetProviderPage.self, from: legacy)
        #expect(legacyPage.hourlyHistory.isEmpty)
    }
}
