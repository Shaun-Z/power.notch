//
//  PowerNotchXPCHelper.swift
//  PowerNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import IOKit
import CoreGraphics
import Darwin
import SQLite3
import zlib

class PowerNotchXPCHelper: NSObject, PowerNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Antigravity CLI Usage Probe

    private static func isInteractiveScreenSessionActive() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked {
            return false
        }
        if let onConsole = dict[kCGSessionOnConsoleKey as String] as? Bool, !onConsole {
            return false
        }
        return true
    }

    private static func ensureNoBrowserShimDirectory() -> String? {
        let dirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("powernotch-nobrowser", isDirectory: true)
        let openShimURL = dirURL.appendingPathComponent("open", isDirectory: false)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if !fm.isExecutableFile(atPath: openShimURL.path) {
                let script = "#!/bin/sh\nexit 1\n"
                try script.write(to: openShimURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openShimURL.path)
            }
            return dirURL.path
        } catch {
            return nil
        }
    }

    private static func resolvedUserHomePath() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    @objc func runAntigravityUsageProbe(with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Never launch `agy` while the screen is locked or off-console:
            // macOS Keychain denies non-interactive reads (exit status 36), which
            // causes `agy` to fall back to interactive browser OAuth login.
            guard Self.isInteractiveScreenSessionActive() else {
                reply(nil)
                return
            }

            let home = Self.resolvedUserHomePath()

            let candidates = [
                "\(home)/.gemini/bin/agy",
                "\(home)/.local/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
                "/usr/bin/agy"
            ]

            guard let executablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                reply(nil)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
            process.arguments = ["--print", "/usage", "--output-format", "json", "--print-timeout", "25s"]
            process.standardInput = FileHandle.nullDevice

            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home
            env["NO_COLOR"] = "1"
            // Block any interactive browser OAuth popup without disabling macOS Keychain silent auth
            // (Note: do NOT set SSH_CONNECTION, which forces `agy` to skip Keychain and always fail silent auth.)
            env["BROWSER"] = "/usr/bin/false"
            env["NO_BROWSER"] = "1"
            env["AGY_NO_BROWSER"] = "1"
            env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"

            var pathParts: [String] = []
            if let shimDir = Self.ensureNoBrowserShimDirectory() {
                pathParts.append(shimDir)
            }
            pathParts.append(contentsOf: [
                "\(home)/.gemini/bin",
                "\(home)/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ])
            if let existing = env["PATH"], !existing.isEmpty {
                pathParts.append(existing)
            }
            env["PATH"] = pathParts.joined(separator: ":")
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let lock = NSLock()
            var didReply = false
            let finishOnce: (String?) -> Void = { value in
                lock.lock()
                let shouldReply = !didReply
                didReply = true
                lock.unlock()
                if shouldReply {
                    reply(value)
                }
            }

            let looksLikeInteractiveLogin: (Data) -> Bool = { data in
                guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
                return text.contains("accounts.google.com/o/oauth")
                    || text.contains("authentication required")
                    || text.contains("please visit the url")
                    || text.contains("starting oauth flow")
                    || text.contains("silent auth failed")
                    || text.contains("please open")
                    || text.contains("not logged into antigravity")
            }

            let outputQueue = DispatchQueue(label: "com.powernotch.helper.agy.io")
            var stdoutData = Data()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    if looksLikeInteractiveLogin(chunk) {
                        if process.isRunning {
                            process.terminate()
                        }
                        finishOnce(nil)
                        return
                    }
                    outputQueue.sync {
                        stdoutData.append(chunk)
                    }
                }
            }
            // Drain stderr and immediately abort if interactive OAuth login starts
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else if looksLikeInteractiveLogin(chunk) {
                    if process.isRunning {
                        process.terminate()
                    }
                    finishOnce(nil)
                }
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                finishOnce(nil)
            }

            process.terminationHandler = { proc in
                timeoutWork.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let combined: Data = outputQueue.sync {
                    if !trailing.isEmpty {
                        stdoutData.append(trailing)
                    }
                    return stdoutData
                }
                if proc.terminationStatus == 0,
                   let text = String(data: combined, encoding: .utf8),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    finishOnce(text)
                } else {
                    finishOnce(nil)
                }
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 28.0, execute: timeoutWork)
            } catch {
                timeoutWork.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                finishOnce(nil)
            }
        }
    }

    // MARK: - Codex Local Workspace Credit Snapshot Reader

    @objc func fetchCodexLocalCreditSnapshot(
        accountId: String,
        email: String,
        with reply: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.lookupCodexLocalCreditSnapshot(accountId: accountId, email: email)
            reply(result)
        }
    }

    private static func lookupCodexLocalCreditSnapshot(accountId: String, email: String) -> String? {
        let home = resolvedUserHomePath()
        let path = "\(home)/Library/Application Support/CodexBar/codex-account-snapshots.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["records"] as? [[String: Any]],
              !records.isEmpty
        else {
            return nil
        }

        let normAcc = accountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let matchedRecord: [String: Any]? = records.first { rec in
            if !normAcc.isEmpty,
               let identity = rec["accountIdentity"] as? [String: Any],
               let ws = (identity["workspaceAccountID"] as? String)?.lowercased(),
               ws == normAcc
            {
                return true
            }
            if !normEmail.isEmpty,
               let recID = (rec["id"] as? String)?.lowercased(),
               recID == normEmail
            {
                return true
            }
            return false
        } ?? (records.count == 1 ? records.first : nil)

        guard let record = matchedRecord,
              let credits = record["credits"] as? [String: Any]
        else {
            return nil
        }

        var payload: [String: Any] = [:]

        if let creditLimit = credits["codexCreditLimit"] as? [String: Any],
           let remaining = creditLimit["remaining"] as? Double
        {
            payload["remaining"] = remaining
            if let limit = creditLimit["limit"] as? Double {
                payload["limit"] = limit
            }
            if let used = creditLimit["used"] as? Double {
                payload["used"] = used
            }
            if let title = creditLimit["title"] as? String, !title.isEmpty {
                payload["title"] = title
            }
        } else if let ok = credits["balanceReadSucceeded"] as? Bool, ok,
                  let remaining = credits["remaining"] as? Double
        {
            payload["remaining"] = remaining
            payload["title"] = "Credits"
        }

        guard !payload.isEmpty,
              let outData = try? JSONSerialization.data(withJSONObject: payload),
              let outStr = String(data: outData, encoding: .utf8)
        else {
            return nil
        }
        return outStr
    }

    // MARK: - Apple Music Local TTML Cache Reader

    @objc func fetchAppleMusicCachedTTML(
        title: String,
        artist: String,
        album: String,
        duration: Double,
        with reply: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.lookupAppleMusicCachedTTML(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
            reply(result)
        }
    }

    private static func lookupAppleMusicCachedTTML(
        title: String,
        artist: String,
        album: String,
        duration: Double
    ) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let home = resolvedUserHomePath()
        let cacheDir = "\(home)/Library/Caches/com.apple.Music"
        let dbPath = "\(cacheDir)/Cache.db"
        let fsCacheDir = "\(cacheDir)/fsCachedData"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 400)

        let sql = """
        SELECT d.receiver_data, d.isDataOnFS
        FROM cfurl_cache_response r
        JOIN cfurl_cache_receiver_data d ON r.entry_ID = d.entry_ID
        WHERE r.request_key LIKE '%lyric%'
        ORDER BY r.entry_ID DESC
        LIMIT 250
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let normTargetTitle = normalizeLyricsMatchText(trimmedTitle)
        let cleanTargetTitle = normalizeLyricsMatchText(stripLyricsTitleSuffixes(trimmedTitle))
        let normTargetArtist = normalizeLyricsMatchText(artist)
        let normTargetAlbum = normalizeLyricsMatchText(album)

        var bestTTML: String?
        var bestScore: Int = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let isOnFS = sqlite3_column_int(stmt, 1) == 1
            let rawData: Data?

            if isOnFS {
                guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
                let fileName = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fileName.isEmpty else { continue }
                let filePath = "\(fsCacheDir)/\(fileName)"
                rawData = try? Data(contentsOf: URL(fileURLWithPath: filePath))
            } else {
                guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
                let length = Int(sqlite3_column_bytes(stmt, 0))
                guard length > 0 else { continue }
                rawData = Data(bytes: bytes, count: length)
            }

            guard let rawData, !rawData.isEmpty else { continue }
            let payloadData: Data
            if rawData.count >= 2 && rawData[0] == 0x1f && rawData[1] == 0x8b {
                guard let decompressed = gunzipData(rawData) else { continue }
                payloadData = decompressed
            } else {
                payloadData = rawData
            }

            guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let items = json["data"] as? [[String: Any]]
            else {
                continue
            }

            for item in items {
                guard let attrs = item["attributes"] as? [String: Any],
                      let cachedName = attrs["name"] as? String,
                      let ttml = extractTTMLFromAppleMusicSongItem(item),
                      !ttml.isEmpty
                else {
                    continue
                }

                let cachedArtist = (attrs["artistName"] as? String) ?? ""
                let cachedAlbum = (attrs["albumName"] as? String) ?? ""
                let cachedDurationSec: Double
                if let ms = attrs["durationInMillis"] as? Double {
                    cachedDurationSec = ms / 1000.0
                } else if let ms = attrs["durationInMillis"] as? Int {
                    cachedDurationSec = Double(ms) / 1000.0
                } else {
                    cachedDurationSec = 0
                }

                let score = scoreAppleMusicCacheMatch(
                    normTargetTitle: normTargetTitle,
                    cleanTargetTitle: cleanTargetTitle,
                    normTargetArtist: normTargetArtist,
                    normTargetAlbum: normTargetAlbum,
                    targetDuration: duration,
                    cachedTitle: cachedName,
                    cachedArtist: cachedArtist,
                    cachedAlbum: cachedAlbum,
                    cachedDuration: cachedDurationSec
                )

                if score > bestScore {
                    bestScore = score
                    bestTTML = ttml
                    // Short-circuit on an unambiguous high-confidence match
                    if score >= 145 {
                        return bestTTML
                    }
                }
            }
        }

        return bestScore >= 90 ? bestTTML : nil
    }

    private static func extractTTMLFromAppleMusicSongItem(_ item: [String: Any]) -> String? {
        guard let rel = item["relationships"] as? [String: Any] else { return nil }
        for relKey in ["syllable-lyrics", "lyrics"] {
            if let relObj = rel[relKey] as? [String: Any],
               let dataArr = relObj["data"] as? [[String: Any]]
            {
                for entry in dataArr {
                    if let attrs = entry["attributes"] as? [String: Any] {
                        if let ttml = attrs["ttmlLocalizations"] as? String, !ttml.isEmpty {
                            return ttml
                        }
                        if let ttml = attrs["ttml"] as? String, !ttml.isEmpty {
                            return ttml
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func scoreAppleMusicCacheMatch(
        normTargetTitle: String,
        cleanTargetTitle: String,
        normTargetArtist: String,
        normTargetAlbum: String,
        targetDuration: Double,
        cachedTitle: String,
        cachedArtist: String,
        cachedAlbum: String,
        cachedDuration: Double
    ) -> Int {
        let normCachedTitle = normalizeLyricsMatchText(cachedTitle)
        let cleanCachedTitle = normalizeLyricsMatchText(stripLyricsTitleSuffixes(cachedTitle))
        let normCachedArtist = normalizeLyricsMatchText(cachedArtist)
        let normCachedAlbum = normalizeLyricsMatchText(cachedAlbum)

        var score = 0
        var titleMatched = false
        if !normTargetTitle.isEmpty && normTargetTitle == normCachedTitle {
            score += 80
            titleMatched = true
        } else if !cleanTargetTitle.isEmpty && cleanTargetTitle == cleanCachedTitle {
            score += 65
            titleMatched = true
        } else if !cleanTargetTitle.isEmpty && !cleanCachedTitle.isEmpty
            && (cleanCachedTitle.contains(cleanTargetTitle) || cleanTargetTitle.contains(cleanCachedTitle))
        {
            score += 40
            titleMatched = true
        }

        guard titleMatched else { return 0 }

        var artistMatched = false
        if !normTargetArtist.isEmpty && !normCachedArtist.isEmpty {
            if normTargetArtist == normCachedArtist {
                score += 50
                artistMatched = true
            } else if normTargetArtist.contains(normCachedArtist) || normCachedArtist.contains(normTargetArtist) {
                score += 35
                artistMatched = true
            }
        }

        var durationClose = false
        if targetDuration > 1 && cachedDuration > 1 {
            let diff = abs(targetDuration - cachedDuration)
            if diff <= 1.5 {
                score += 40
                durationClose = true
            } else if diff <= 3.5 {
                score += 25
                durationClose = true
            } else if diff <= 7.0 {
                score += 5
            } else {
                // Reject mismatched duration (e.g. Live vs Studio version)
                return 0
            }
        }

        if !normTargetAlbum.isEmpty && !normCachedAlbum.isEmpty {
            if normTargetAlbum == normCachedAlbum {
                score += 20
            } else if normTargetAlbum.contains(normCachedAlbum) || normCachedAlbum.contains(normTargetAlbum) {
                score += 10
            }
        }

        // Require either artist match or close duration confirmation
        guard artistMatched || durationClose else { return 0 }
        return score
    }

    private static func normalizeLyricsMatchText(_ text: String) -> String {
        let folded = text
            .applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return folded
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
    }

    private static func stripLyricsTitleSuffixes(_ title: String) -> String {
        var cleaned = title
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[\(\[\{（【「][^\)\]\}\}）】」]*[\)\]\}）】」]"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[-–—]\s*(feat\.?|ft\.?|featuring|remix|live|acoustic|radio edit|remaster(ed)?|single version).*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gunzipData(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: data.count * 3)
        let chunkSize = 16_384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        let status: Int32 = data.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            stream.avail_in = uInt(data.count)

            var ret: Int32 = Z_OK
            while ret == Z_OK {
                let written: Int = buffer.withUnsafeMutableBytes { outPtr in
                    guard let outBase = outPtr.bindMemory(to: Bytef.self).baseAddress else { return 0 }
                    stream.next_out = outBase
                    stream.avail_out = uInt(chunkSize)
                    ret = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if written > 0 {
                    output.append(buffer, count: written)
                }
                if ret == Z_STREAM_END {
                    break
                }
                if ret != Z_OK {
                    return ret
                }
            }
            return ret
        }

        return status == Z_STREAM_END ? output : nil
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
