//
//  AIUsageHistoryCollector.swift
//  powerNotch
//
//  Collects 30-day daily usage history (tokens, spend, requests) per AI provider from:
//  - Local Antigravity SQLite conversation DBs
//  - Timestamped local OpenAI Codex rollout JSONL sessions
//  - Local Claude Code project JSONL logs
//  - Local OpenCode SQLite database (mapped across providers)
//  - Persistent 30-day rolling balance-delta ledger for API balance providers (DeepSeek, MiMo, OpenRouter, etc.)
//

import Foundation
import SQLite3

private struct AIUsageProviderLedger: Codable, Sendable {
    var lastObservedRemaining: Double?
    var lastObservedCurrency: String?
    var lastObservedUsedThisPeriod: Double?
    var daily: [String: AIUsageLedgerEntry] = [:]
}

private struct AIUsagePersistentLedger: Codable, Sendable {
    var providers: [String: AIUsageProviderLedger] = [:]
}

enum AIUsageHistoryCollector {
    private static let ledgerLock = NSLock()
    private static let ledgerFileName = "ai-usage-daily-ledger.json"

    private static func ledgerFileURL() -> URL? {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AIUsageWidgetBridgeConstants.appGroupID
        ) {
            return groupURL.appendingPathComponent(ledgerFileName, isDirectory: false)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(ledgerFileName, isDirectory: false)
    }

    /// Generates the ordered list of the last `days` local calendar day keys ("YYYY-MM-DD"), oldest first.
    nonisolated static func recentDayKeys(days: Int = 30, now: Date = Date()) -> [String] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let formatter = makeDayFormatter()
        return (0..<days).reversed().compactMap { offset -> String? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            return formatter.string(from: date)
        }
    }

    nonisolated private static func makeDayFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    /// Records latest snapshot balances into the persistent 30-day ledger to accumulate daily spend for API-balance providers.
    nonisolated static func recordLedgerObservation(
        snapshots: [AIProviderID: AIProviderSnapshot],
        now: Date = Date()
    ) {
        guard let url = ledgerFileURL() else { return }
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        var ledger = loadLedger(from: url)
        let validKeys = Set(recentDayKeys(days: 35, now: now))
        let todayKey = makeDayFormatter().string(from: now)

        for (provider, snapshot) in snapshots {
            var pLedger = ledger.providers[provider.rawValue] ?? AIUsageProviderLedger()
            // Prune entries older than 35 days
            pLedger.daily = pLedger.daily.filter { validKeys.contains($0.key) }

            if let balance = snapshot.balance {
                let currency = balance.currency.uppercased()
                if let remaining = balance.remaining {
                    pLedger.lastObservedUsedThisPeriod = nil
                    if let prev = pLedger.lastObservedRemaining,
                       pLedger.lastObservedCurrency == currency
                    {
                        let spentDelta = prev - remaining
                        if spentDelta > 0.0001 {
                            var entry = pLedger.daily[todayKey] ?? AIUsageLedgerEntry()
                            entry.addBalanceDelta(spentDelta, currency: currency)
                            if entry.requests == 0 {
                                entry.requests = 1
                            }
                            pLedger.daily[todayKey] = entry
                        }
                    }
                    pLedger.lastObservedRemaining = remaining
                    pLedger.lastObservedCurrency = currency
                } else if let used = balance.usedThisPeriod {
                    pLedger.lastObservedRemaining = nil
                    if let prevUsed = pLedger.lastObservedUsedThisPeriod,
                       pLedger.lastObservedCurrency == currency
                    {
                        let usedDelta = used - prevUsed
                        if usedDelta > 0.0001 {
                            var entry = pLedger.daily[todayKey] ?? AIUsageLedgerEntry()
                            entry.addBalanceDelta(usedDelta, currency: currency)
                            pLedger.daily[todayKey] = entry
                        }
                    }
                    pLedger.lastObservedUsedThisPeriod = used
                    pLedger.lastObservedCurrency = currency
                }
            }

            ledger.providers[provider.rawValue] = pLedger
        }

        saveLedger(ledger, to: url)
    }

    /// Collects 30-day daily usage series for all enabled providers off the main thread.
    nonisolated static func collect30DayHistories(
        for providers: [AIProviderID],
        snapshots: [AIProviderID: AIProviderSnapshot],
        realUserHomePath: String,
        now: Date = Date()
    ) -> [AIProviderID: [AIUsageWidgetDailyPoint]] {
        let dayKeys = recentDayKeys(days: 30, now: now)
        let validKeySet = Set(dayKeys)
        let cal = Calendar.current
        let cutoffDate = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(-30 * 86400)
        let cutoffSec = Int64(cutoffDate.timeIntervalSince1970)
        let formatter = makeDayFormatter()

        var bucketsByProvider: [AIProviderID: [String: AIUsageDailyBucket]] = [:]
        for p in providers {
            bucketsByProvider[p] = [:]
        }

        // 1. OpenCode DB (covers multiple providers via providerID)
        let openCodeBuckets = scanOpenCodeDB(
            homePath: realUserHomePath,
            cutoffSec: cutoffSec,
            validKeys: validKeySet,
            formatter: formatter
        )
        for (provider, days) in openCodeBuckets where bucketsByProvider[provider] != nil {
            for (day, bucket) in days {
                var existing = bucketsByProvider[provider]?[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                bucketsByProvider[provider]?[day] = existing
            }
        }

        // 2. Antigravity local conversation SQLite DBs
        if providers.contains(.antigravity) {
            let agBuckets = scanAntigravity30Days(
                homePath: realUserHomePath,
                cutoffDate: cutoffDate,
                cutoffSec: cutoffSec,
                validKeys: validKeySet,
                formatter: formatter
            )
            for (day, bucket) in agBuckets {
                var existing = bucketsByProvider[.antigravity]?[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                bucketsByProvider[.antigravity]?[day] = existing
            }
        }

        // 3. Codex timestamped rollout sessions
        if providers.contains(.codex) {
            let codexBuckets = scanCodex30Days(
                homePath: realUserHomePath,
                cutoffDate: cutoffDate,
                validKeys: validKeySet,
                formatter: formatter
            )
            for (day, bucket) in codexBuckets {
                var existing = bucketsByProvider[.codex]?[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                bucketsByProvider[.codex]?[day] = existing
            }
        }

        // 4. Claude Code local project JSONL transcripts
        if providers.contains(.claude) {
            let claudeBuckets = scanClaude30Days(
                homePath: realUserHomePath,
                cutoffDate: cutoffDate,
                validKeys: validKeySet,
                formatter: formatter
            )
            for (day, bucket) in claudeBuckets {
                var existing = bucketsByProvider[.claude]?[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                bucketsByProvider[.claude]?[day] = existing
            }
        }

        // 5. GitHub Copilot CLI / SDK local session-state JSONL records
        if providers.contains(.copilot) {
            let copilotBuckets = scanCopilotSessionState30Days(
                homePath: realUserHomePath,
                cutoffDate: cutoffDate,
                validKeys: validKeySet,
                formatter: formatter
            )
            for (day, bucket) in copilotBuckets {
                var existing = bucketsByProvider[.copilot]?[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                bucketsByProvider[.copilot]?[day] = existing
            }
        }

        // 6. Pi Agent local session JSONL transcripts (DeepSeek, MiMo/Xiaomi, Copilot, Codex, Claude, etc.)
        let piBuckets = scanPiSessions30Days(
            homePath: realUserHomePath,
            cutoffDate: cutoffDate,
            validKeys: validKeySet,
            formatter: formatter
        )
        for (provider, days) in piBuckets where bucketsByProvider[provider] != nil {
            for (day, bucket) in days {
                var existing = bucketsByProvider[provider]?[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                bucketsByProvider[provider]?[day] = existing
            }
        }

        // Keep balance observations separate from USD local estimates, including their currency.
        var ledgerCosts: [AIProviderID: [String: AIUsageLedgerEntry]] = [:]
        if let url = ledgerFileURL() {
            ledgerLock.lock()
            let ledger = loadLedger(from: url)
            ledgerLock.unlock()
            for provider in providers {
                ledgerCosts[provider] = ledger.providers[provider.rawValue]?.daily
            }
        }

        var result: [AIProviderID: [AIUsageWidgetDailyPoint]] = [:]
        for provider in providers {
            let map = bucketsByProvider[provider] ?? [:]
            let points = dayKeys.map { key in
                let bucket = map[key] ?? AIUsageDailyBucket()
                let observation = ledgerCosts[provider]?[key]
                var costs = observation?.costs ?? []
                if bucket.cost > 0 {
                    costs.append(AIUsageCost(amount: bucket.cost, currency: "USD", source: .localEstimate))
                }
                return AIUsageWidgetDailyPoint(
                    dayKey: key,
                    tokens: bucket.tokens,
                    requests: bucket.requests,
                    costs: costs
                )
            }
            result[provider] = AIUsageCostSeries.select(points, preferredCurrency: snapshots[provider]?.balance?.currency)
        }
        return result
    }

    // MARK: - OpenCode SQLite Scanner

    nonisolated private static func scanOpenCodeDB(
        homePath: String,
        cutoffSec: Int64,
        validKeys: Set<String>,
        formatter: DateFormatter
    ) -> [AIProviderID: [String: AIUsageDailyBucket]] {
        let dbPath = "\(homePath)/.local/share/opencode/opencode.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db
        else { return [:] }
        defer { sqlite3_close(db) }

        let cutoffMs = cutoffSec * 1000
        let sql = """
            SELECT time_created,
                   json_extract(data, '$.providerID'),
                   COALESCE(json_extract(data, '$.cost'), 0),
                   COALESCE(json_extract(data, '$.tokens.input'), 0),
                   COALESCE(json_extract(data, '$.tokens.output'), 0),
                   COALESCE(json_extract(data, '$.tokens.reasoning'), 0),
                   COALESCE(json_extract(data, '$.tokens.cache.read'), 0),
                   COALESCE(json_extract(data, '$.tokens.cache.write'), 0)
            FROM message
            WHERE time_created >= ?
              AND json_extract(data, '$.role') = 'assistant';
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)

        var output: [AIProviderID: [String: AIUsageDailyBucket]] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let tsMs = sqlite3_column_int64(stmt, 0)
            let rawProvider = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let provider = mapOpenCodeProviderID(rawProvider) else { continue }

            let date = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0)
            let dayKey = formatter.string(from: date)
            guard validKeys.contains(dayKey) else { continue }

            let recordedCost = sqlite3_column_double(stmt, 2)
            let inTok = sqlite3_column_int64(stmt, 3)
            let outTok = sqlite3_column_int64(stmt, 4)
            let reasonTok = sqlite3_column_int64(stmt, 5)
            let cacheRead = sqlite3_column_int64(stmt, 6)
            let cacheWrite = sqlite3_column_int64(stmt, 7)
            let totalTok = max(0, inTok + outTok + reasonTok + cacheRead + cacheWrite)

            let cost: Double = {
                if recordedCost > 0 { return recordedCost }
                guard totalTok > 0 else { return 0 }
                return estimateBlendedCostUSD(
                    uncachedInput: inTok,
                    cachedInput: cacheRead,
                    cacheWrite: cacheWrite,
                    output: outTok + reasonTok
                )
            }()

            var dayMap = output[provider] ?? [:]
            var bucket = dayMap[dayKey] ?? AIUsageDailyBucket()
            bucket.tokens += totalTok
            bucket.cost += cost
            bucket.requests += 1
            dayMap[dayKey] = bucket
            output[provider] = dayMap
        }

        return output
    }

    nonisolated private static func mapOpenCodeProviderID(_ raw: String) -> AIProviderID? {
        let lower = raw.lowercased()
        if lower.contains("openai") || lower.contains("codex") { return .codex }
        if lower.contains("anthropic") || lower.contains("claude") { return .claude }
        if lower.contains("copilot") { return .copilot }
        if lower.contains("cursor") { return .cursor }
        if lower.contains("google") || lower.contains("gemini") || lower.contains("antigravity") { return .antigravity }
        if lower.contains("deepseek") { return .deepseek }
        if lower.contains("mimo") || lower.contains("xiaomi") { return .mimo }
        if lower.contains("openrouter") { return .openrouter }
        if lower.contains("zai") || lower.contains("zhipu") || lower.contains("bigmodel") || lower.contains("glm") { return .zai }
        if lower.contains("kimi") || lower.contains("moonshot") { return .kimi }
        if lower.contains("opencode") { return .opencode }
        return nil
    }

    // MARK: - Antigravity 30-Day SQLite Scanner

    nonisolated private static func scanAntigravity30Days(
        homePath: String,
        cutoffDate: Date,
        cutoffSec: Int64,
        validKeys: Set<String>,
        formatter: DateFormatter
    ) -> [String: AIUsageDailyBucket] {
        let fm = FileManager.default
        let dirs = [
            "\(homePath)/.gemini/antigravity/conversations",
            "\(homePath)/Library/Developer/Xcode/CodingAssistant/antigravity/antigravity-acp/conversations"
        ]

        var byDay: [String: AIUsageDailyBucket] = [:]

        for dirPath in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in files where fileURL.pathExtension == "db" {
                if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mtime = vals.contentModificationDate,
                   mtime < cutoffDate
                {
                    continue
                }

                var db: OpaquePointer?
                guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                      let db
                else { continue }
                defer { sqlite3_close(db) }

                let sql = "SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx DESC;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
                defer { sqlite3_finalize(stmt) }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let byteCount = Int(sqlite3_column_bytes(stmt, 0))
                    guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { continue }
                    let blob = Data(bytes: rawPtr, count: byteCount)
                    guard let parsed = parseAntigravityMetadataDetailed(blob) else { continue }
                    if parsed.timestamp < cutoffSec {
                        break
                    }
                    let dayKey = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(parsed.timestamp)))
                    guard validKeys.contains(dayKey) else { continue }

                    var bucket = byDay[dayKey] ?? AIUsageDailyBucket()
                    bucket.tokens += parsed.totalTokens
                    bucket.requests += 1
                    bucket.cost += estimateBlendedCostUSD(
                        uncachedInput: parsed.uncachedInput,
                        cachedInput: parsed.cachedInput,
                        cacheWrite: 0,
                        output: parsed.output
                    )
                    byDay[dayKey] = bucket
                }
            }
        }

        return byDay
    }

    private struct AntigravityStepDetailed {
        let timestamp: Int64
        let uncachedInput: Int64
        let cachedInput: Int64
        let output: Int64
        var totalTokens: Int64 { uncachedInput + cachedInput + output }
    }

    nonisolated private static func parseAntigravityMetadataDetailed(_ data: Data) -> AntigravityStepDetailed? {
        var timestamp: Int64?
        var usageSlice: Data?

        iterateProtobuf(data) { fieldNumber, wireType, _, bytesValue in
            if fieldNumber == 1, wireType == 2, let tsBytes = bytesValue {
                iterateProtobuf(tsBytes) { tsField, tsWire, tsVal, _ in
                    if tsField == 1, tsWire == 0, let secs = tsVal {
                        let s = Int64(bitPattern: secs)
                        if s >= 1_600_000_000 && s <= 2_000_000_000 {
                            timestamp = s
                        }
                    }
                }
            } else if fieldNumber == 9, wireType == 2, let uBytes = bytesValue {
                usageSlice = uBytes
            }
        }

        guard let ts = timestamp, let uBytes = usageSlice else { return nil }

        var uncachedInput: UInt64 = 0
        var output: UInt64 = 0
        var cachedInput: UInt64 = 0
        var outPartA: UInt64 = 0
        var outPartB: UInt64 = 0
        var hasPartA = false
        var hasPartB = false

        iterateProtobuf(uBytes) { fieldNumber, wireType, varintValue, _ in
            guard wireType == 0, let val = varintValue else { return }
            switch fieldNumber {
            case 2: uncachedInput = val
            case 3: output = val
            case 5: cachedInput = val
            case 9:
                outPartA = val
                hasPartA = true
            case 10:
                outPartB = val
                hasPartB = true
            default:
                break
            }
        }

        if (hasPartA || hasPartB), (outPartA &+ outPartB) != output {
            return nil
        }

        let total = uncachedInput &+ cachedInput &+ output
        guard total > 0, total <= UInt64(Int64.max) else { return nil }
        return AntigravityStepDetailed(
            timestamp: ts,
            uncachedInput: Int64(min(uncachedInput, UInt64(Int64.max))),
            cachedInput: Int64(min(cachedInput, UInt64(Int64.max))),
            output: Int64(min(output, UInt64(Int64.max)))
        )
    }

    nonisolated private static func iterateProtobuf(
        _ data: Data,
        _ body: (_ fieldNumber: UInt64, _ wireType: UInt8, _ varintValue: UInt64?, _ bytesValue: Data?) -> Void
    ) {
        let bytes = [UInt8](data)
        var index = 0
        let count = bytes.count

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < count && shift < 64 {
                let b = bytes[index]
                index += 1
                result |= UInt64(b & 0x7F) << shift
                if (b & 0x80) == 0 { return result }
                shift += 7
            }
            return nil
        }

        while index < count {
            guard let tag = readVarint() else { return }
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x07)
            switch wireType {
            case 0:
                guard let v = readVarint() else { return }
                body(fieldNumber, wireType, v, nil)
            case 1:
                guard index + 8 <= count else { return }
                index += 8
                body(fieldNumber, wireType, nil, nil)
            case 2:
                guard let lenU64 = readVarint() else { return }
                let len = Int(lenU64)
                guard len >= 0, index + len <= count else { return }
                let slice = Data(bytes[index..<(index + len)])
                index += len
                body(fieldNumber, wireType, nil, slice)
            case 5:
                guard index + 4 <= count else { return }
                index += 4
                body(fieldNumber, wireType, nil, nil)
            default:
                return
            }
        }
    }

    // MARK: - OpenAI Codex 30-Day Scanner

    nonisolated private static func scanCodex30Days(
        homePath: String,
        cutoffDate: Date,
        validKeys: Set<String>,
        formatter: DateFormatter
    ) -> [String: AIUsageDailyBucket] {
        var byDay: [String: AIUsageDailyBucket] = [:]

        // Thread-level SQLite counters have no daily allocation: attributing an entire
        // session to updated_at invents daily usage and can double-count cross-day rollouts.
        // Only timestamped rollout increments can contribute to the daily chart.
        let sessionsRoot = URL(fileURLWithPath: "\(homePath)/.codex/sessions")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified < cutoffDate {
                continue
            }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fileBuckets = CodexUsageLogParser.dailyBuckets(in: text, validKeys: validKeys, formatter: formatter)
            for (day, bucket) in fileBuckets {
                var existing = byDay[day] ?? AIUsageDailyBucket()
                existing.tokens += bucket.tokens
                existing.cost += bucket.cost
                existing.requests += bucket.requests
                byDay[day] = existing
            }
        }

        return byDay
    }

    // MARK: - Claude Code 30-Day JSONL Scanner

    nonisolated private static func scanClaude30Days(
        homePath: String,
        cutoffDate: Date,
        validKeys: Set<String>,
        formatter: DateFormatter
    ) -> [String: AIUsageDailyBucket] {
        let projectsRoot = URL(fileURLWithPath: "\(homePath)/.claude/projects")
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsRoot.path) else { return [:] }

        var byDay: [String: AIUsageDailyBucket] = [:]
        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        guard let enumerator = fm.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = vals.contentModificationDate,
               mtime < cutoffDate
            {
                continue
            }

            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("\"usage\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let msg = obj["message"] as? [String: Any]
                guard let usage = (msg?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) else {
                    continue
                }

                let inT = int64Val(usage["input_tokens"])
                let outT = int64Val(usage["output_tokens"])
                let cacheRead = int64Val(usage["cache_read_input_tokens"])
                let cacheCreate = int64Val(usage["cache_creation_input_tokens"])
                let total = inT + outT + cacheRead + cacheCreate
                guard total > 0 else { continue }

                let tsDate: Date? = {
                    if let tsStr = obj["timestamp"] as? String {
                        return isoWithFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                    }
                    return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }()
                guard let tsDate else { continue }
                let dayKey = formatter.string(from: tsDate)
                guard validKeys.contains(dayKey) else { continue }

                var b = byDay[dayKey] ?? AIUsageDailyBucket()
                b.tokens += total
                b.requests += 1
                b.cost += estimateBlendedCostUSD(
                    uncachedInput: inT,
                    cachedInput: cacheRead,
                    cacheWrite: cacheCreate,
                    output: outT
                )
                byDay[dayKey] = b
            }
        }

        return byDay
    }

    // MARK: - GitHub Copilot CLI / SDK 30-Day JSONL Scanner

    nonisolated private static func scanCopilotSessionState30Days(
        homePath: String,
        cutoffDate: Date,
        validKeys: Set<String>,
        formatter: DateFormatter
    ) -> [String: AIUsageDailyBucket] {
        let root = URL(fileURLWithPath: "\(homePath)/.copilot/session-state")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [:] }

        var byDay: [String: AIUsageDailyBucket] = [:]
        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = vals.contentModificationDate,
               mtime < cutoffDate
            {
                continue
            }

            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("\"session.usage_record\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "session.usage_record",
                      let dataDict = obj["data"] as? [String: Any],
                      let usage = dataDict["usage"] as? [String: Any]
                else { continue }

                let inT = int64Val(usage["inputTokens"])
                let outT = int64Val(usage["outputTokens"])
                let cacheRead = int64Val(usage["cacheReadTokens"])
                let cacheWrite = int64Val(usage["cacheWriteTokens"])
                let reasoning = int64Val(usage["reasoningTokens"])
                let total = max(0, inT + outT + cacheRead + cacheWrite)
                guard total > 0 else { continue }

                let tsDate: Date? = {
                    if let tsStr = obj["timestamp"] as? String {
                        return isoWithFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                    }
                    return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }()
                guard let tsDate else { continue }
                let dayKey = formatter.string(from: tsDate)
                guard validKeys.contains(dayKey) else { continue }

                let uncachedIn = max(0, inT - cacheRead - cacheWrite)
                let estCost = estimateBlendedCostUSD(
                    uncachedInput: uncachedIn,
                    cachedInput: cacheRead,
                    cacheWrite: cacheWrite,
                    output: outT + reasoning
                )

                var b = byDay[dayKey] ?? AIUsageDailyBucket()
                b.tokens += total
                b.cost += estCost
                b.requests += 1
                byDay[dayKey] = b
            }
        }

        return byDay
    }

    // MARK: - Pi Agent 30-Day JSONL Scanner (DeepSeek, MiMo, Copilot, Codex, Claude, etc.)

    nonisolated private static func scanPiSessions30Days(
        homePath: String,
        cutoffDate: Date,
        validKeys: Set<String>,
        formatter: DateFormatter
    ) -> [AIProviderID: [String: AIUsageDailyBucket]] {
        let root = URL(fileURLWithPath: "\(homePath)/.pi/agent/sessions")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [:] }

        var output: [AIProviderID: [String: AIUsageDailyBucket]] = [:]
        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = vals.contentModificationDate,
               mtime < cutoffDate
            {
                continue
            }

            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("\"usage\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let msg = obj["message"] as? [String: Any]
                guard let usage = (msg?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) else {
                    continue
                }

                let rawProvider = (msg?["provider"] as? String) ?? (obj["provider"] as? String) ?? ""
                guard let provider = mapOpenCodeProviderID(rawProvider) else { continue }

                let inT = int64Val(usage["input"])
                let outT = int64Val(usage["output"])
                let cacheRead = int64Val(usage["cacheRead"])
                let cacheWrite = int64Val(usage["cacheWrite"])
                let reasoning = int64Val(usage["reasoning"])
                let explicitTotal = int64Val(usage["totalTokens"])
                let total = max(explicitTotal, inT + outT + cacheRead + cacheWrite)

                var costUSD: Double = 0
                if let costDict = usage["cost"] as? [String: Any] {
                    costUSD = doubleVal(costDict["total"])
                } else {
                    costUSD = doubleVal(usage["cost"])
                }
                if costUSD <= 0 && total > 0 {
                    costUSD = estimateBlendedCostUSD(
                        uncachedInput: inT,
                        cachedInput: cacheRead,
                        cacheWrite: cacheWrite,
                        output: outT + reasoning
                    )
                }

                guard total > 0 || costUSD > 0 else { continue }

                let tsDate: Date? = {
                    if let tsStr = obj["timestamp"] as? String,
                       let d = isoWithFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                    {
                        return d
                    }
                    if let tsMs = msg?["timestamp"] as? Double, tsMs > 1_000_000_000 {
                        return Date(timeIntervalSince1970: tsMs > 10_000_000_000 ? tsMs / 1000.0 : tsMs)
                    }
                    if let tsMs = msg?["timestamp"] as? Int64, tsMs > 1_000_000_000 {
                        return Date(timeIntervalSince1970: tsMs > 10_000_000_000 ? Double(tsMs) / 1000.0 : Double(tsMs))
                    }
                    return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }()
                guard let tsDate else { continue }
                let dayKey = formatter.string(from: tsDate)
                guard validKeys.contains(dayKey) else { continue }

                var dayMap = output[provider] ?? [:]
                var b = dayMap[dayKey] ?? AIUsageDailyBucket()
                b.tokens += total
                b.cost += costUSD
                b.requests += 1
                dayMap[dayKey] = b
                output[provider] = dayMap
            }
        }

        return output
    }

    // MARK: - Helpers

    nonisolated private static func estimateBlendedCostUSD(
        uncachedInput: Int64,
        cachedInput: Int64,
        cacheWrite: Int64,
        output: Int64
    ) -> Double {
        let inCost = Double(max(0, uncachedInput)) / 1_000_000.0 * 3.0
        let cachedCost = Double(max(0, cachedInput)) / 1_000_000.0 * 0.30
        let cacheWriteCost = Double(max(0, cacheWrite)) / 1_000_000.0 * 3.75
        let outCost = Double(max(0, output)) / 1_000_000.0 * 15.0
        return inCost + cachedCost + cacheWriteCost + outCost
    }

    nonisolated private static func doubleVal(_ raw: Any?) -> Double {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? Int64 { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        return 0
    }

    nonisolated private static func int64Val(_ raw: Any?) -> Int64 {
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int { return Int64(v) }
        if let v = raw as? Double { return Int64(v) }
        if let v = raw as? NSNumber { return v.int64Value }
        return 0
    }

    nonisolated private static func loadLedger(from url: URL) -> AIUsagePersistentLedger {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AIUsagePersistentLedger.self, from: data)
        else { return AIUsagePersistentLedger() }
        return decoded
    }

    nonisolated private static func saveLedger(_ ledger: AIUsagePersistentLedger, to url: URL) {
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
