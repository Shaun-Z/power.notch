//
//  TrendWindow.swift
//  AIUsageCore
//
//  Trend charts are addressed by bucket keys: "2026-11-23" for a day, "2026-11-23T14" for an
//  hour. The keys and the formatters that produce them live together so the collector cannot
//  bucket events into a key the window never asked for.
//

import Foundation

enum AIUsageTrendWindow {
    static let dayFormat = "yyyy-MM-dd"
    /// Hour buckets carry the hour as an ISO-style suffix, so a key can never be mistaken for a day.
    static let hourFormat = "yyyy-MM-dd'T'HH"

    static func dayFormatter(calendar: Calendar = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dayFormat
        return formatter
    }

    static func hourFormatter(calendar: Calendar = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = hourFormat
        return formatter
    }

    /// The last `days` calendar days, oldest first, ending with today.
    static func dayKeys(days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let todayStart = calendar.startOfDay(for: now)
        let formatter = dayFormatter(calendar: calendar)
        return (0..<max(0, days)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: todayStart).map { formatter.string(from: $0) }
        }
    }

    /// The last `hours` hours, oldest first, ending with the hour `now` falls in.
    static func hourKeys(hours: Int = 24, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let formatter = hourFormatter(calendar: calendar)
        guard let thisHour = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: now)
        ) else { return [] }
        return (0..<max(0, hours)).reversed().compactMap { offset in
            calendar.date(byAdding: .hour, value: -offset, to: thisHour).map { formatter.string(from: $0) }
        }
    }
}
