//
//  CodexCredits.swift
//  AIUsageCore
//
//  Codex has two credit regimes. An individual subscription reads its prepaid balance straight
//  out of `/wham/usage` (`credits.balance`). An education / business / enterprise workspace gets
//  the same object with `has_credits: true` and `balance: null` — the backend says credits exist
//  but refuses to put a number in that field, while ChatGPT's own usage page shows the remaining
//  credits. For those accounts the same bearer token can read the per-user monthly spend control:
//
//    GET /accounts/<accountId>/spend-controls/current-user/monthly-usage
//    {"balance_unit":"credit",
//     "effective_monthly_limit":{"limit":8000,"enforcement_mode":"HARD_CAP"},
//     "current_month_usage":7451.714}
//
//  `/accounts/<id>/remaining_balance` is deliberately not used: it answers 401 for a plain
//  workspace member ("Only accounts with admin rights can perform this action").
//
//  A provider with a subscription pool keeps its rate windows; the credit allowance travels next
//  to them as its own quota instead of being folded into (or dropped behind) the pool.
//

import Foundation

enum AIUsageCodexCredits {
    /// Where the remaining amount came from, so the UI can say what the ceiling means.
    enum Source: String, Equatable, Sendable {
        /// `credits.balance` from `/wham/usage`: prepaid credits, no ceiling.
        case prepaidBalance
        /// Spend control: this month's allowance in credits, minus what has been spent.
        case monthlyCap
    }

    struct View: Equatable, Sendable {
        var source: Source
        var remaining: Double?
        var usedThisPeriod: Double?
        var limit: Double?

        /// Share of the allowance already spent, when the account states a ceiling.
        var usedPercent: Double? {
            guard let limit, limit > 0, let used = usedThisPeriod ?? remaining.map({ max(0, limit - $0) })
            else { return nil }
            return max(0, min(100, used / limit * 100))
        }

        /// `"7452/8000 cr"` — the same shape the settings row and ring detail use.
        var usageText: String? {
            guard let limit, limit > 0,
                  let used = usedThisPeriod ?? remaining.map({ max(0, limit - $0) })
            else { return nil }
            return String(format: "%.0f/%.0f cr", used, limit)
        }
    }

    /// Resolves the credit allowance for one usage document, optionally enriched by the monthly
    /// spend control. Returns `nil` when the account reports no credit regime at all, or reports
    /// credits without any readable number (unlimited credits, or a cap route that refused).
    static func view(usageJSON: [String: Any], monthlyUsageJSON: [String: Any]? = nil) -> View? {
        guard let credits = usageJSON["credits"] as? [String: Any] else { return nil }

        if let prepaid = number(credits["balance"]) {
            return View(source: .prepaidBalance, remaining: prepaid, usedThisPeriod: nil, limit: nil)
        }

        guard (credits["has_credits"] as? Bool) == true else { return nil }
        // Unlimited credits have no remaining number to show, and asking the cap route about them
        // would invent a ceiling the account does not have.
        guard (credits["unlimited"] as? Bool) != true else { return nil }

        return monthlyView(monthlyUsageJSON)
    }

    /// Projects the spend-control document onto a credit allowance. A document that states another
    /// unit cannot be read as credits, and one without a positive ceiling has no number to show.
    static func monthlyView(_ document: [String: Any]?) -> View? {
        guard let document else { return nil }
        if let unit = document["balance_unit"] as? String,
           !["credit", "credits"].contains(unit.lowercased())
        {
            return nil
        }
        guard let limit = document["effective_monthly_limit"] as? [String: Any],
              let total = number(limit["limit"]),
              total > 0,
              let used = number(document["current_month_usage"])
        else { return nil }
        return View(
            source: .monthlyCap,
            remaining: max(0, total - used),
            usedThisPeriod: used,
            limit: total
        )
    }

    /// The first day of the next calendar month: the spend-control allowance resets with the
    /// billing month, and the document states no period end of its own.
    static func nextMonthStart(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    /// The spend-control route, addressed from the same API base the usage route was read from.
    static func monthlyUsageURL(base: String, accountID: String) -> URL? {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !root.isEmpty else { return nil }
        for suffix in ["/wham/usage", "/backend-api"] where root.hasSuffix(suffix) {
            root.removeLast(suffix.count)
        }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return URL(string: "\(root)/backend-api/accounts/\(encoded)/spend-controls/current-user/monthly-usage")
    }

    private static func number(_ any: Any?) -> Double? {
        let value: Double?
        if let d = any as? Double {
            value = d
        } else if let i = any as? Int {
            value = Double(i)
        } else if let n = any as? NSNumber {
            value = n.doubleValue
        } else if let s = any as? String {
            value = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }
}
