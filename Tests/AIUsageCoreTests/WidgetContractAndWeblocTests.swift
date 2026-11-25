//
//  WidgetContractAndWeblocTests.swift
//  AIUsageCoreTests
//
//  Regression tests covering:
//  - shared widget payload contract round-trips (deduplicated into AIUsageCore)
//  - dynamic App Group resolution edge cases
//  - .webloc XML property-list serialization (escaping correctness)
//
//  Deterministic: fixed whole-second dates, no clock/locale/network dependence.
//

import Foundation
import Testing
@testable import AIUsageCore

// MARK: - Fixtures

/// Fixed whole-second reference date: the app/widget bridge encodes JSON with `.iso8601`,
/// which drops sub-second precision, so fixtures stay at second granularity.
private let referenceDate = Date(timeIntervalSince1970: 1_760_000_000)

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

/// JSONEncoder key order is not part of the wire contract (Foundation does not sort keys by default),
/// so byte-level comparisons use sorted keys while the decode path stays on the app's exact strategy.
private func makeSortedEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func makeWindow(
    id: String = "window_5h",
    label: String = "5-Hour Session",
    usedPercent: Double = 34.5,
    detailText: String? = nil,
    resetAt: Date? = referenceDate,
    isEstimated: Bool = false
) -> AIUsageWidgetWindow {
    AIUsageWidgetWindow(
        id: id,
        label: label,
        usedPercent: usedPercent,
        detailText: detailText,
        resetAt: resetAt,
        isEstimated: isEstimated
    )
}

private func makeBalance(
    currency: String = "USD",
    remaining: Double? = 12.75,
    usedThisPeriod: Double? = 4.25,
    limit: Double? = 17,
    periodLabel: String? = "Nov",
    formattedBreakdown: String? = "12.75 / 17.00 USD"
) -> AIUsageWidgetBalance {
    AIUsageWidgetBalance(
        currency: currency,
        remaining: remaining,
        usedThisPeriod: usedThisPeriod,
        limit: limit,
        periodLabel: periodLabel,
        formattedRemaining: "12.75",
        compactFormattedRemaining: "12.8",
        formattedBreakdown: formattedBreakdown
    )
}

private func makeProviderPage(
    id: String = "claude",
    planName: String? = "Max",
    accountLabel: String? = "user@example.com",
    balance: AIUsageWidgetBalance? = nil,
    ringGroups: [AIUsageWidgetRingGroup]? = nil,
    dailyHistory: [AIUsageWidgetDailyPoint] = []
) -> AIUsageWidgetProviderPage {
    AIUsageWidgetProviderPage(
        id: id,
        displayName: "Claude",
        shortName: "Claude",
        iconAssetName: "ProviderIcon-claude",
        symbolName: "sparkles",
        accentRed: 0.88,
        accentGreen: 0.52,
        accentBlue: 0.36,
        innerRed: 0.36,
        innerGreen: 0.78,
        innerBlue: 1.0,
        planName: planName,
        accountLabel: accountLabel,
        sourceLabel: "oauth",
        statusNote: nil,
        errorMessage: nil,
        updatedAt: referenceDate,
        ringGroups: ringGroups ?? [
            AIUsageWidgetRingGroup(
                id: "dual_default",
                label: "All",
                outerWindow: makeWindow(id: "claude_five_hour"),
                innerWindow: makeWindow(id: "claude_seven_day", label: "Weekly All Models", usedPercent: 52)
            )
        ],
        balance: balance,
        dailyHistory: dailyHistory,
        costCurrencySymbol: "$"
    )
}

private func makePayload(
    schemaVersion: Int = AIUsageWidgetSharedConstants.currentSchemaVersion,
    showRemainingPercent: Bool = true,
    hideAccountEmails: Bool = false,
    providers: [AIUsageWidgetProviderPage]? = nil
) -> AIUsageWidgetPayload {
    AIUsageWidgetPayload(
        schemaVersion: schemaVersion,
        updatedAt: referenceDate,
        showRemainingPercent: showRemainingPercent,
        hideAccountEmails: hideAccountEmails,
        providers: providers ?? [makeProviderPage()]
    )
}

// MARK: - Shared widget payload contract

@Suite("Widget payload contract")
struct AIUsageWidgetContractTests {

    @Test("Payload with every optional populated round-trips unchanged")
    func payloadWithAllFieldsRoundTrips() throws {
        let page = makeProviderPage(
            balance: makeBalance(),
            dailyHistory: [
                AIUsageWidgetDailyPoint(dayKey: "2025-10-09", tokens: 1_234_567, cost: 2.5, requests: 42),
                AIUsageWidgetDailyPoint(dayKey: "2025-10-10", tokens: 0, cost: 0, requests: 0)
            ]
        )
        let payload = makePayload(providers: [page])

        let encoded = try makeSortedEncoder().encode(payload)
        let decoded = try makeDecoder().decode(AIUsageWidgetPayload.self, from: encoded)
        let reencoded = try makeSortedEncoder().encode(decoded)

        #expect(encoded == reencoded, "encode -> decode -> encode must be lossless")
        #expect(try makeDecoder().decode(AIUsageWidgetPayload.self, from: try makeEncoder().encode(payload)).providers == payload.providers,
                "the app's unsorted .iso8601 encoding must decode identically")
        #expect(decoded.schemaVersion == payload.schemaVersion)
        #expect(decoded.updatedAt == referenceDate)
        #expect(decoded.showRemainingPercent == payload.showRemainingPercent)
        #expect(decoded.hideAccountEmails == payload.hideAccountEmails)
        #expect(decoded.providers == payload.providers)
        #expect(decoded.providers.first?.balance == makeBalance())
        #expect(decoded.providers.first?.dailyHistory.count == 2)
    }

    @Test("Payload with nil optionals keeps them nil after round-trip")
    func payloadWithNilOptionalsRoundTrips() throws {
        let page = makeProviderPage(
            planName: nil,
            accountLabel: nil,
            ringGroups: [
                AIUsageWidgetRingGroup(
                    id: "single",
                    label: "Single",
                    outerWindow: makeWindow(detailText: nil, resetAt: nil),
                    innerWindow: nil
                )
            ]
        )
        let payload = makePayload(
            showRemainingPercent: false,
            hideAccountEmails: true,
            providers: [page]
        )

        let decoded = try makeDecoder().decode(
            AIUsageWidgetPayload.self,
            from: try makeEncoder().encode(payload)
        )

        let decodedPage = try #require(decoded.providers.first)
        #expect(decodedPage.planName == nil)
        #expect(decodedPage.accountLabel == nil)
        #expect(decodedPage.balance == nil)
        #expect(decoded.showRemainingPercent == false)
        #expect(decoded.hideAccountEmails == true)

        let group = try #require(decodedPage.ringGroups.first)
        #expect(group.innerWindow == nil)
        #expect(group.isDual == false)
        #expect(group.outerWindow.resetAt == nil)
        #expect(group.outerWindow.detailText == nil)
    }

    @Test("Ring group with inner window round-trips")
    func ringGroupWithInnerWindowRoundTrips() throws {
        let group = AIUsageWidgetRingGroup(
            id: "dual",
            label: "Claude/GPT",
            outerWindow: makeWindow(id: "outer", usedPercent: 25),
            innerWindow: makeWindow(id: "inner", usedPercent: 40, isEstimated: true)
        )
        let decoded = try makeDecoder().decode(
            AIUsageWidgetRingGroup.self,
            from: try makeEncoder().encode(group)
        )
        #expect(decoded == group)
        #expect(decoded.isDual)
        #expect(decoded.innerWindow?.isEstimated == true)
    }

    @Test("Window round-trips unicode and XML-sensitive detail text")
    func windowRoundTripsUnicodeDetail() throws {
        let window = makeWindow(
            usedPercent: 99.5,
            detailText: "Resets in 2h — «&<>\"'» 日本語 😀",
            isEstimated: true
        )
        let decoded = try makeDecoder().decode(
            AIUsageWidgetWindow.self,
            from: try makeEncoder().encode(window)
        )
        #expect(decoded == window)
        #expect(decoded.detailText == window.detailText)
        #expect(decoded.clampedUsedPercent == 99.5)
        #expect(decoded.remainingPercent == 0.5)
    }

    @Test("Balance round-trips with all numeric optionals nil")
    func balanceWithNilNumericsRoundTrips() throws {
        let balance = AIUsageWidgetBalance(
            currency: "CNY",
            remaining: nil,
            usedThisPeriod: nil,
            limit: nil,
            periodLabel: nil,
            formattedRemaining: "—",
            compactFormattedRemaining: "—",
            formattedBreakdown: nil
        )
        let decoded = try makeDecoder().decode(
            AIUsageWidgetBalance.self,
            from: try makeEncoder().encode(balance)
        )
        #expect(decoded == balance)
        #expect(decoded.remaining == nil)
        #expect(decoded.formattedBreakdown == nil)
        #expect(decoded.currency == "CNY")
    }

    @Test("Balance round-trips with every numeric populated")
    func balanceWithNumericsRoundTrips() throws {
        let balance = makeBalance()
        let decoded = try makeDecoder().decode(
            AIUsageWidgetBalance.self,
            from: try makeEncoder().encode(balance)
        )
        #expect(decoded == balance)
    }

    @Test("Shared schema version constant is 3 and drives the sample payload")
    func schemaVersionIsThree() {
        #expect(AIUsageWidgetSharedConstants.currentSchemaVersion == 3)
        #expect(AIUsageWidgetPayload.sample.schemaVersion == AIUsageWidgetSharedConstants.currentSchemaVersion)
    }

    @Test("Sample payload survives the app -> widget JSON round-trip")
    func samplePayloadRoundTrips() throws {
        // `.sample` uses `Date()` (sub-second); the bridge's `.iso8601` contract truncates to seconds,
        // so equality is asserted on the decoded wire form, which is what the widget actually renders.
        let firstWireForm = try makeDecoder().decode(
            AIUsageWidgetPayload.self,
            from: try makeEncoder().encode(AIUsageWidgetPayload.sample)
        )
        let secondWireForm = try makeDecoder().decode(
            AIUsageWidgetPayload.self,
            from: try makeEncoder().encode(firstWireForm)
        )
        #expect(firstWireForm.schemaVersion == 3)
        #expect(firstWireForm.providers.count == AIUsageWidgetPayload.sample.providers.count)
        #expect(firstWireForm.providers.map(\.id) == AIUsageWidgetPayload.sample.providers.map(\.id))
        #expect(firstWireForm.providers == secondWireForm.providers)
        #expect(firstWireForm.providers.allSatisfy { !$0.ringGroups.isEmpty })
    }

    @Test("Provider page written by an older schema still decodes (defaults preserved)")
    func legacyProviderPageDecodesWithDefaults() throws {
        // Pre-dedupe payloads could omit dailyHistory / costCurrencySymbol for some providers.
        let legacyJSON = """
        {
          "id": "codex",
          "displayName": "OpenAI Codex",
          "shortName": "Codex",
          "iconAssetName": "ProviderIcon-codex",
          "symbolName": "terminal.fill",
          "accentRed": 0.16,
          "accentGreen": 0.78,
          "accentBlue": 0.58,
          "innerRed": 0.36,
          "innerGreen": 0.78,
          "innerBlue": 1.0,
          "planName": null,
          "accountLabel": null,
          "sourceLabel": null,
          "statusNote": null,
          "errorMessage": null,
          "updatedAt": null,
          "ringGroups": [],
          "balance": null
        }
        """
        let page = try makeDecoder().decode(
            AIUsageWidgetProviderPage.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(page.dailyHistory.isEmpty)
        #expect(page.costCurrencySymbol == "$")
        #expect(page.ringGroups.isEmpty)
        #expect(page.balance == nil)
    }

    @Test("ISO-8601 contract keeps whole-second dates stable")
    func iso8601KeepsWholeSecondDatesStable() throws {
        let window = makeWindow(resetAt: referenceDate)
        let decoded = try makeDecoder().decode(
            AIUsageWidgetWindow.self,
            from: try makeEncoder().encode(window)
        )
        #expect(decoded.resetAt == referenceDate,
                "app and widget both use .iso8601; changing the strategy would shift reset countdowns")
    }
}

// MARK: - Dynamic App Group resolution

@Suite("App Group resolution")
struct AIUsageAppGroupTests {
    private static let fallback = "com.powernotch.app"
    private static let validGroup = "ABCDE12345.com.powernotch.app"
    private static let template = "$(TeamIdentifierPrefix)com.powernotch.app"

    enum InfoPlistCase: String, CaseIterable, Sendable {
        case nilDictionary
        case emptyDictionary
        case missingKey
        case emptyValue
        case whitespaceOnly
        case unexpandedTemplate
        case partiallyExpanded
        case nonStringValue
        case validGroup
        case paddedValidGroup

        var infoDictionary: [String: Any]? {
            switch self {
            case .nilDictionary:
                return nil
            case .emptyDictionary:
                return [:]
            case .missingKey:
                return ["CFBundleIdentifier": "com.powernotch.app"]
            case .emptyValue:
                return ["PowerNotchAppGroup": ""]
            case .whitespaceOnly:
                return ["PowerNotchAppGroup": "   \n\t"]
            case .unexpandedTemplate:
                return ["PowerNotchAppGroup": "$(TeamIdentifierPrefix)com.powernotch.app"]
            case .partiallyExpanded:
                return ["PowerNotchAppGroup": "ABC$(TeamIdentifierPrefix)"]
            case .nonStringValue:
                return ["PowerNotchAppGroup": 42]
            case .validGroup:
                return ["PowerNotchAppGroup": "ABCDE12345.com.powernotch.app"]
            case .paddedValidGroup:
                return ["PowerNotchAppGroup": "  ABCDE12345.com.powernotch.app\n\t"]
            }
        }
        var expected: String {
            switch self {
            case .validGroup, .paddedValidGroup:
                return "ABCDE12345.com.powernotch.app"
            default:
                return "com.powernotch.app"
            }
        }
    }

    @Test("Team-prefixed app group passes through untouched")
    func validGroupPassesThrough() {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(
            infoDictionary: ["PowerNotchAppGroup": Self.validGroup]
        )
        #expect(resolved == Self.validGroup)
    }

    @Test("Whitespace-padded app group is trimmed")
    func whitespacePaddedGroupIsTrimmed() {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(
            infoDictionary: ["PowerNotchAppGroup": "  \(Self.validGroup)\n\t"]
        )
        #expect(resolved == Self.validGroup)
    }

    @Test("Nil Info.plist dictionary falls back instead of crashing")
    func nilDictionaryFallsBack() {
        #expect(AIUsageWidgetSharedConstants.resolvedAppGroupID(infoDictionary: nil) == Self.fallback)
    }

    @Test("Missing PowerNotchAppGroup key falls back")
    func missingKeyFallsBack() {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(
            infoDictionary: ["CFBundleIdentifier": "com.powernotch.app"]
        )
        #expect(resolved == Self.fallback)
    }

    @Test("Empty app group value falls back")
    func emptyValueFallsBack() {
        #expect(AIUsageWidgetSharedConstants.resolvedAppGroupID(infoDictionary: ["PowerNotchAppGroup": ""])
                == Self.fallback)
    }

    @Test("Whitespace-only app group value falls back")
    func whitespaceOnlyValueFallsBack() {
        #expect(AIUsageWidgetSharedConstants.resolvedAppGroupID(infoDictionary: ["PowerNotchAppGroup": "   \n"])
                == Self.fallback)
    }

    @Test("Unexpanded Xcode build variable falls back")
    func unexpandedTemplateFallsBack() {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(
            infoDictionary: ["PowerNotchAppGroup": Self.template]
        )
        #expect(resolved == Self.fallback)
    }

    @Test("Partially expanded build variable falls back")
    func partiallyExpandedFallsBack() {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(
            infoDictionary: ["PowerNotchAppGroup": "ABC$(TeamIdentifierPrefix)"]
        )
        #expect(resolved == Self.fallback)
    }

    @Test("Non-string app group value falls back")
    func nonStringValueFallsBack() {
        #expect(AIUsageWidgetSharedConstants.resolvedAppGroupID(infoDictionary: ["PowerNotchAppGroup": 42])
                == Self.fallback)
    }

    @Test("Resolution never returns empty or unexpanded values",
          arguments: InfoPlistCase.allCases)
    func resolutionIsAlwaysUsable(testCase: InfoPlistCase) {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(infoDictionary: testCase.infoDictionary)
        #expect(!resolved.isEmpty, "\(testCase.rawValue): empty app group")
        #expect(!resolved.contains("$("), "\(testCase.rawValue): unexpanded build variable leaked")
        #expect(resolved == resolved.trimmingCharacters(in: .whitespacesAndNewlines),
                "\(testCase.rawValue): untrimmed app group")
    }

    @Test("Each Info.plist variant resolves to its exact expected group",
          arguments: InfoPlistCase.allCases)
    func eachVariantResolvesExactly(testCase: InfoPlistCase) {
        let resolved = AIUsageWidgetSharedConstants.resolvedAppGroupID(infoDictionary: testCase.infoDictionary)
        #expect(resolved == testCase.expected, "\(testCase.rawValue): unexpected resolution")
    }
}

// MARK: - .webloc XML serialization

@Suite("Webloc serialization")
struct WeblocSerializerTests {
    struct WeblocCase: Sendable {
        let label: String
        let url: URL
    }

    static let cases: [WeblocCase] = [
        WeblocCase(label: "plain", url: URL(string: "https://example.com")!),
        WeblocCase(label: "ampersand-query",
                   url: URL(string: "https://example.com/search?q=swift&lang=en&page=2")!),
        WeblocCase(label: "fragment-with-ampersand",
                   url: URL(string: "https://example.com/a?x=1&y=2#section&two")!),
        WeblocCase(label: "percent-escaped-entities",
                   url: URL(string: "https://example.com/?q=%3Cscript%3E%20%26%20%22quoted%22")!),
        WeblocCase(label: "literal-entity-text", url: URL(string: "https://example.com/?q=a&amp;b")!),
        WeblocCase(label: "apostrophe", url: URL(string: "https://example.com/it's/a?b='c'")!),
        WeblocCase(label: "unicode-path-and-query",
                   url: URL(string: "https://example.com/日本語/路径?q=日本語#標籤")!),
        WeblocCase(label: "emoji", url: URL(string: "https://example.com/emoji?q=%F0%9F%98%80")!),
        WeblocCase(label: "spaces", url: URL(string: "https://example.com/path/with%20space?q=a%20b")!),
        WeblocCase(label: "port-and-userinfo", url: URL(string: "https://user:pass@example.com:8443/x?y=z")!),
        WeblocCase(label: "file-url", url: URL(string: "file:///tmp/shelf%20item.txt")!)
    ]

    @Test("Webloc data is an XML property list carrying exactly the URL",
          arguments: WeblocSerializerTests.cases)
    func weblocIsXMLPropertyList(testCase: WeblocCase) throws {
        let data = try WeblocSerializer.data(for: testCase.url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let dictionary = try #require(parsed as? [String: String])
        #expect(format == .xml, "\(testCase.label): webloc must be XML")
        #expect(dictionary.count == 1, "\(testCase.label): unexpected keys \(dictionary.keys.sorted())")
        #expect(dictionary["URL"] == testCase.url.absoluteString, "\(testCase.label): URL mismatch")
    }

    @Test("Ampersands are escaped exactly once")
    func ampersandEscapedOnce() throws {
        let url = URL(string: "https://example.com/?a=1&b=2")!
        let weblocData = try WeblocSerializer.data(for: url)
        let xml = try #require(String(data: weblocData, encoding: .utf8))
        #expect(xml.contains("&amp;"), "raw & must be escaped for XML")
        #expect(!xml.contains("&amp;amp;"), "entity must not be double-escaped")
        #expect(xml.contains(url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")))
    }

    @Test("Literal entity text is not double-escaped")
    func literalEntityNotDoubleEscaped() throws {
        let url = URL(string: "https://example.com/?q=a&amp;b")!
        let data = try WeblocSerializer.data(for: url)
        let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let parsed = try #require(raw as? [String: String])
        #expect(parsed["URL"] == url.absoluteString)
        let value = try #require(parsed["URL"])
        #expect(!value.contains("&amp;amp;"), "entity text must survive exactly one encoding")
    }

    @Test("Unicode URL text survives the property-list round-trip")
    func unicodeSurvives() throws {
        let url = URL(string: "https://example.com/日本語?q=😀&x=1")!
        let raw = try PropertyListSerialization.propertyList(
            from: try WeblocSerializer.data(for: url), options: [], format: nil
        )
        let parsed = try #require(raw as? [String: String])
        #expect(parsed["URL"] == url.absoluteString)
    }

    @Test("Serialization is deterministic for the same URL")
    func serializationIsDeterministic() throws {
        let url = URL(string: "https://example.com/?a=1&b=2#frag")!
        let first = try WeblocSerializer.data(for: url)
        let second = try WeblocSerializer.data(for: url)
        #expect(first == second)
    }

    @Test("Webloc output parses as XML text, not binary")
    func weblocIsHumanReadableXML() throws {
        let weblocData = try WeblocSerializer.data(for: URL(string: "https://example.com")!)
        let xml = try #require(String(data: weblocData, encoding: .utf8))
        #expect(xml.contains("<plist version=\"1.0\">"))
        #expect(xml.contains("<key>URL</key>"))
    }
}

// MARK: - Moved shared-model behaviour (regression guard for the dedupe)

@Suite("Shared widget model behaviour")
struct AIUsageWidgetModelBehaviourTests {

    @Test("Reset countdown text matches the pre-dedupe widget copy")
    func resetCountdownTextBoundaries() {
        let now = referenceDate
        let window = makeWindow(resetAt: nil)
        #expect(window.resetCountdownText(referenceDate: now) == nil, "no reset date -> no countdown")

        let past = makeWindow(resetAt: now.addingTimeInterval(-60))
        #expect(past.resetCountdownText(referenceDate: now) == "Resetting")

        let underOneMinute = makeWindow(resetAt: now.addingTimeInterval(30))
        #expect(underOneMinute.resetCountdownText(referenceDate: now) == "1m",
                "sub-minute resets must not render 0m")

        let fiftyNineMinutes = makeWindow(resetAt: now.addingTimeInterval(59 * 60))
        #expect(fiftyNineMinutes.resetCountdownText(referenceDate: now) == "59m")

        let twoAndHalfHours = makeWindow(resetAt: now.addingTimeInterval(2 * 3600 + 30 * 60))
        #expect(twoAndHalfHours.resetCountdownText(referenceDate: now) == "2h 30m")

        let threeDaysFourHours = makeWindow(resetAt: now.addingTimeInterval(3 * 86400 + 4 * 3600))
        #expect(threeDaysFourHours.resetCountdownText(referenceDate: now) == "3d 4h")
    }

    @Test("allWindows orders outer before inner per group")
    func allWindowsOrdering() {
        let first = AIUsageWidgetRingGroup(id: "g1", label: "G1",
                                           outerWindow: makeWindow(id: "o1"),
                                           innerWindow: makeWindow(id: "i1"))
        let second = AIUsageWidgetRingGroup(id: "g2", label: "G2",
                                            outerWindow: makeWindow(id: "o2"),
                                            innerWindow: nil)
        let page = makeProviderPage(ringGroups: [first, second])
        #expect(page.allWindows.map(\.id) == ["o1", "i1", "o2"])
    }

    @Test("30-day totals ignore negative samples")
    func totalsClampNegatives() {
        let page = makeProviderPage(dailyHistory: [
            AIUsageWidgetDailyPoint(dayKey: "d1", tokens: 100, cost: 1.5, requests: 2),
            AIUsageWidgetDailyPoint(dayKey: "d2", tokens: -50, cost: -2.5, requests: -3),
            AIUsageWidgetDailyPoint(dayKey: "d3", tokens: 10, cost: 0.5, requests: 1)
        ])
        #expect(page.total30dTokens == 110)
        #expect(page.total30dCost == 2.0)
        #expect(page.total30dRequests == 3)
    }

    @Test("Display percent switches between used and remaining")
    func displayPercentSwitches() {
        let window = makeWindow(usedPercent: 34)
        #expect(window.clampedUsedPercent == 34)
        #expect(window.remainingPercent == 66)
        #expect(window.displayPercent(showRemaining: false) == 34)
        #expect(window.displayPercent(showRemaining: true) == 66)
        #expect(abs(window.ringProgress(showRemaining: true) - 0.66) < 0.0001)
    }

    @Test("Used percent is clamped for out-of-range input")
    func usedPercentClamped() {
        #expect(makeWindow(usedPercent: -10).clampedUsedPercent == 0)
        #expect(makeWindow(usedPercent: 140).clampedUsedPercent == 100)
        #expect(makeWindow(usedPercent: 140).remainingPercent == 0)
    }

    @Test("Legacy daily point cost is not relabelled as currency")
    func legacyDailyPointCostNotRelabelled() throws {
        let json = #"{"dayKey":"2025-10-09","tokens":123,"requests":4,"cost":9.99}"#
        let point = try makeDecoder().decode(AIUsageWidgetDailyPoint.self, from: Data(json.utf8))
        #expect(point.costs.isEmpty)
        #expect(point.selectedCost == nil)
        #expect(point.cost == 0, "unknown-currency legacy amount must not be shown as spend")
        #expect(point.tokens == 123)
    }

    @Test("Unknown payload keys are tolerated for forward compatibility")
    func unknownKeysTolerated() throws {
        let json = #"{"schemaVersion":3,"updatedAt":"2025-10-09T08:53:20Z","showRemainingPercent":true,"hideAccountEmails":false,"providers":[],"futureField":"ignored"}"#
        let payload = try makeDecoder().decode(AIUsageWidgetPayload.self, from: Data(json.utf8))
        #expect(payload.schemaVersion == 3)
        #expect(payload.providers.isEmpty)
    }

    @Test("A payload with no providers round-trips")
    func emptyProvidersRoundTrip() throws {
        let payload = makePayload(providers: [])
        let decoded = try makeDecoder().decode(
            AIUsageWidgetPayload.self,
            from: try makeEncoder().encode(payload)
        )
        #expect(decoded.providers.isEmpty)
        #expect(decoded.schemaVersion == AIUsageWidgetSharedConstants.currentSchemaVersion)
    }
}
