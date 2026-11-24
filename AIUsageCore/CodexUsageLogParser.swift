import Foundation

enum CodexUsageLogParser {
    /// Cumulative counters belong to a session, but increments belong to the event's day.
    /// Consume counters even for events outside the requested range to establish the baseline.
    static func dailyBuckets(in text: String, validKeys: Set<String>, formatter: DateFormatter) -> [String: AIUsageDailyBucket] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var previousTotal: Int64 = 0
        var buckets: [String: AIUsageDailyBucket] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("token_count"),
                  let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any]
            else { continue }

            let last = info["last_token_usage"] as? [String: Any]
            let input = count(last?["input_tokens"])
            let cached = min(input, count(last?["cached_input_tokens"]))
            let output = count(last?["output_tokens"])
            let lastTokens = max(count(last?["total_tokens"]), input + output)
            let delta: Int64
            if let total = info["total_token_usage"] as? [String: Any], total["total_tokens"] != nil {
                let current = count(total["total_tokens"])
                // A counter reset (e.g. compaction) starts a new baseline.
                delta = current >= previousTotal ? current - previousTotal : (last == nil ? current : lastTokens)
                previousTotal = current
            } else {
                delta = lastTokens
                previousTotal += delta
            }
            guard delta > 0,
                  let timestamp = event["timestamp"] as? String,
                  let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp)
            else { continue }
            let day = formatter.string(from: date)
            guard validKeys.contains(day) else { continue }

            var bucket = buckets[day] ?? AIUsageDailyBucket()
            bucket.tokens += delta
            bucket.requests += 1
            if lastTokens > 0 {
                // Reasoning output is a subset of output_tokens, not an extra charge.
                let estimate = (Double(input - cached) * 3 + Double(cached) * 0.30 + Double(output) * 15) / 1_000_000
                bucket.cost += estimate * Double(delta) / Double(lastTokens)
            } else {
                bucket.cost += Double(delta) / 1_000_000 * 1.60
            }
            buckets[day] = bucket
        }
        return buckets
    }

    private static func count(_ value: Any?) -> Int64 {
        guard let number = value as? NSNumber else { return 0 }
        return max(0, number.int64Value)
    }
}
