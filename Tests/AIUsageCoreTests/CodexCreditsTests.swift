import Foundation
import Testing
@testable import AIUsageCore

/// Codex answers with two credit regimes, and only one of them puts a number in the usage
/// document. These pin the rules that decide which number the card shows.
struct CodexCreditsTests {
    private func usage(credits: [String: Any]?) -> [String: Any] {
        var document: [String: Any] = [
            "plan_type": "education",
            "rate_limit": [
                "primary_window": ["used_percent": 0, "limit_window_seconds": 18_000],
                "secondary_window": ["used_percent": 100, "limit_window_seconds": 604_800],
            ],
        ]
        if let credits {
            document["credits"] = credits
        }
        return document
    }

    private func monthlyCap(unit: String? = "credit", limit: Double? = 8_000, used: Double? = 7_451.714) -> [String: Any] {
        var document: [String: Any] = [:]
        if let unit {
            document["balance_unit"] = unit
        }
        if let limit {
            document["effective_monthly_limit"] = ["limit": limit, "enforcement_mode": "HARD_CAP"]
        }
        if let used {
            document["current_month_usage"] = used
        }
        return document
    }

    @Test func prepaidBalanceIsReportedForAnIndividualSubscription() {
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": 42.5])
        )
        #expect(view?.source == .prepaidBalance)
        #expect(view?.remaining == 42.5)
        #expect(view?.limit == nil)
    }

    @Test func prepaidBalanceWinsOverTheMonthlySpendControl() {
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": 5]),
            monthlyUsageJSON: monthlyCap()
        )
        #expect(view?.source == .prepaidBalance)
        #expect(view?.remaining == 5)
    }

    @Test func workspaceAccountProjectsTheMonthlyAllowance() {
        // The usage route says credits exist but refuses to name a balance; the spend control
        // carries the ceiling and this month's spend instead.
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap()
        )
        #expect(view?.source == .monthlyCap)
        #expect(view?.usedThisPeriod == 7_451.714)
        #expect(view?.limit == 8_000)
        #expect(view?.remaining.map { abs($0 - 548.286) < 0.001 } == true)
    }

    @Test func exhaustedAllowanceClampsAtZero() {
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap(used: 9_120)
        )
        #expect(view?.remaining == 0)
    }

    @Test func accountWithoutCreditsReportsNothing() {
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": false, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap()
        )
        #expect(view == nil)
    }

    @Test func usageDocumentWithoutCreditsReportsNothing() {
        #expect(AIUsageCodexCredits.view(usageJSON: usage(credits: nil), monthlyUsageJSON: monthlyCap()) == nil)
    }

    @Test func unlimitedCreditsHaveNoNumberToShow() {
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": true, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap()
        )
        #expect(view == nil)
    }

    @Test func refusedSpendControlLeavesCreditsUnknownInsteadOfFailing() {
        #expect(
            AIUsageCodexCredits.view(
                usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
                monthlyUsageJSON: nil
            ) == nil
        )
    }

    @Test func nonCreditUnitIsNotProjectedAsCredits() {
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap(unit: "usd")
        )
        #expect(view == nil)
    }

    @Test func spendControlWithoutACeilingOrSpendIsIgnored() {
        let noCeiling = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap(limit: nil)
        )
        let noSpend = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap(used: nil)
        )
        let zeroCeiling = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap(limit: 0)
        )
        #expect(noCeiling == nil)
        #expect(noSpend == nil)
        #expect(zeroCeiling == nil)
    }

    @Test func aCappedAllowanceReportsTheShareItHasSpent() {
        // A ceiling turns the allowance into a quota ring, so the view has to state the share and
        // the "used/limit" text a ring row shows.
        let view = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": NSNull()]),
            monthlyUsageJSON: monthlyCap()
        )
        #expect(view?.source == .monthlyCap)
        #expect(view?.usedPercent.map { abs($0 - 93.146425) < 0.001 } == true)
        #expect(view?.usageText == "7452/8000 cr")

        // Prepaid credits have no ceiling, so there is no share to draw — they stay a text line.
        let prepaid = AIUsageCodexCredits.view(
            usageJSON: usage(credits: ["has_credits": true, "unlimited": false, "balance": 42.5])
        )
        #expect(prepaid?.usedPercent == nil)
        #expect(prepaid?.usageText == nil)
    }

    @Test func theAllowanceResetsWithTheNextCalendarMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_795_608_000) // 2026-11-25T12:00:00Z
        let reset = try #require(AIUsageCodexCredits.nextMonthStart(after: now, calendar: calendar))
        let formatter = ISO8601DateFormatter()
        #expect(formatter.string(from: reset) == "2026-12-01T00:00:00Z")
    }

    @Test func spendControlURLIsAddressedFromTheUsageBase() {
        let expected = "https://chatgpt.com/backend-api/accounts/acct-1/spend-controls/current-user/monthly-usage"
        #expect(
            AIUsageCodexCredits.monthlyUsageURL(base: "https://chatgpt.com/backend-api", accountID: "acct-1")?
                .absoluteString == expected
        )
        #expect(
            AIUsageCodexCredits.monthlyUsageURL(base: "https://chatgpt.com/backend-api/wham/usage", accountID: "acct-1")?
                .absoluteString == expected
        )
        #expect(
            AIUsageCodexCredits.monthlyUsageURL(base: "https://chatgpt.com/", accountID: "acct-1")?
                .absoluteString == expected
        )
        #expect(AIUsageCodexCredits.monthlyUsageURL(base: "https://chatgpt.com/backend-api", accountID: "  ") == nil)
        #expect(AIUsageCodexCredits.monthlyUsageURL(base: " ", accountID: "acct-1") == nil)
    }
}
