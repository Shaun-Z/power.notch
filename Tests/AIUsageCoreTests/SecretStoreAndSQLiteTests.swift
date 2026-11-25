//
//  SecretStoreAndSQLiteTests.swift
//  AIUsageCoreTests
//
//  Regression tests covering:
//  - POSIXAtomicSecretFileStore: 0700 dir / 0600 file permissions, atomic write, symlink refusal
//  - DualTrackSecretStore: adaptive Keychain primary + fallback on -34018 + legacy migration
//  - SQLiteReadOnlyOpener: busy_timeout configuration, special-char paths, non-existent path safety
//  - AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup
//

import Darwin
import Foundation
import Security
import SQLite3
import Testing
@testable import AIUsageCore

private func makeTempDirectory(name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("powernotch-secret-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class MockKeychainBackend: SecretKeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: String] = [:]
    var readUnavailableStatus: OSStatus?
    var writeUnavailableStatus: OSStatus?
    var writeCalls: [(account: String, value: String?)] = []

    func read(account: String) -> KeychainBackendReadResult {
        lock.lock()
        defer { lock.unlock() }
        if let status = readUnavailableStatus {
            return .unavailable(status)
        }
        return .available(values[account])
    }

    func write(_ value: String?, account: String) -> KeychainBackendWriteResult {
        lock.lock()
        defer { lock.unlock() }
        writeCalls.append((account, value))
        if let status = writeUnavailableStatus {
            return .unavailable(status)
        }
        if let value {
            values[account] = value
        } else {
            values.removeValue(forKey: account)
        }
        return .available
    }
}

@Suite("POSIXAtomicSecretFileStore")
struct POSIXAtomicSecretFileStoreTests {
    @Test("Creates 0700 dir and 0600 file atomically and removes keys cleanly")
    func permissionsAndRoundTrip() throws {
        let root = try makeTempDirectory(name: "secrets")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent("nested", isDirectory: true)
        let file = dir.appendingPathComponent("ai-usage-secrets.json", isDirectory: false)
        let store = POSIXAtomicSecretFileStore(fileURL: file)

        store.write("sk-alpha", account: "openai.secret")
        store.write("sk-beta", account: "claude.secret")

        #expect(store.read(account: "openai.secret") == "sk-alpha")
        #expect(store.read(account: "claude.secret") == "sk-beta")

        var dirStat = stat()
        #expect(lstat(dir.path, &dirStat) == 0)
        #expect((dirStat.st_mode & 0o777) == 0o700)

        var fileStat = stat()
        #expect(lstat(file.path, &fileStat) == 0)
        #expect((fileStat.st_mode & 0o777) == 0o600)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["ai-usage-secrets.json"], "no leftover .tmp sibling files allowed")

        store.remove(account: "openai.secret")
        #expect(store.read(account: "openai.secret") == nil)
        #expect(store.read(account: "claude.secret") == "sk-beta")
    }

    @Test("Refuses symlinked target file and symlinked parent directory")
    func refusesSymlinks() throws {
        let root = try makeTempDirectory(name: "symlinks")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Symlinked target file
        let realTarget = root.appendingPathComponent("real-target.json")
        try Data("sentinel".utf8).write(to: realTarget)
        let symlinkFile = root.appendingPathComponent("ai-usage-secrets.json")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realTarget)

        let fileStore = POSIXAtomicSecretFileStore(fileURL: symlinkFile)
        fileStore.write("evil", account: "codex.secret")
        #expect(try String(contentsOf: realTarget, encoding: .utf8) == "sentinel")
        #expect(fileStore.read(account: "codex.secret") == nil)

        // 2. Symlinked parent directory
        let realDir = root.appendingPathComponent("real-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlinkDir = root.appendingPathComponent("dir-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

        let dirStore = POSIXAtomicSecretFileStore(
            fileURL: symlinkDir.appendingPathComponent("ai-usage-secrets.json")
        )
        dirStore.write("evil", account: "codex.secret")
        #expect(try FileManager.default.contentsOfDirectory(atPath: realDir.path).isEmpty)
        #expect(dirStore.read(account: "codex.secret") == nil)
    }
}

@Suite("DualTrackSecretStore")
struct DualTrackSecretStoreTests {
    @Test("Falls back to POSIX file store when Keychain returns errSecMissingEntitlement (-34018)")
    func fallbackOnMissingEntitlement() throws {
        let root = try makeTempDirectory(name: "dual-fallback")
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("ai-usage-secrets.json")
        let fileStore = POSIXAtomicSecretFileStore(fileURL: file)
        let backend = MockKeychainBackend()
        backend.readUnavailableStatus = errSecMissingEntitlement
        backend.writeUnavailableStatus = errSecMissingEntitlement

        let store = DualTrackSecretStore(keychain: backend, fileStore: fileStore)
        store.write("  sk-local-only \n", account: "cursor.secret")
        #expect(store.read(account: "cursor.secret") == "sk-local-only")
        #expect(fileStore.read(account: "cursor.secret") == "sk-local-only")

        store.write("   ", account: "cursor.secret")
        #expect(store.read(account: "cursor.secret") == nil)
        #expect(fileStore.read(account: "cursor.secret") == nil)
    }

    @Test("Migrates legacy file secret into Keychain on read and purges file entry")
    func migratesLegacySecretOnRead() throws {
        let root = try makeTempDirectory(name: "dual-migrate")
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("ai-usage-secrets.json")
        let fileStore = POSIXAtomicSecretFileStore(fileURL: file)
        fileStore.write("sk-legacy", account: "deepseek.secret")

        let backend = MockKeychainBackend()
        let store = DualTrackSecretStore(keychain: backend, fileStore: fileStore)

        let loaded = store.read(account: "deepseek.secret")
        #expect(loaded == "sk-legacy")
        #expect(backend.values["deepseek.secret"] == "sk-legacy")
        #expect(fileStore.read(account: "deepseek.secret") == nil)
    }

    @Test("Writes to Keychain when available and clears stale file entry")
    func writesToKeychainAndClearsFile() throws {
        let root = try makeTempDirectory(name: "dual-primary")
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("ai-usage-secrets.json")
        let fileStore = POSIXAtomicSecretFileStore(fileURL: file)
        fileStore.write("stale-secret", account: "zai.secret")

        let backend = MockKeychainBackend()
        let store = DualTrackSecretStore(keychain: backend, fileStore: fileStore)

        store.write("  sk-fresh  ", account: "zai.secret")
        #expect(backend.values["zai.secret"] == "sk-fresh")
        #expect(fileStore.read(account: "zai.secret") == nil)
        #expect(store.read(account: "zai.secret") == "sk-fresh")

        store.write("", account: "zai.secret")
        #expect(backend.values["zai.secret"] == nil)
        #expect(store.read(account: "zai.secret") == nil)
    }
}

@Suite("SQLiteReadOnlyOpener")
struct SQLiteReadOnlyOpenerTests {
    private func createWALDatabase(at dbURL: URL) throws {
        var writer: OpaquePointer?
        let rc = sqlite3_open_v2(
            dbURL.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        #expect(rc == SQLITE_OK)
        let db = try #require(writer)
        defer { sqlite3_close(db) }

        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('ok');", nil, nil, nil) == SQLITE_OK)
    }

    private func querySingleText(_ db: OpaquePointer, sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    private func querySingleInt(_ db: OpaquePointer, sql: String) -> Int32? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(stmt, 0)
    }

    @Test("Opens WAL database read-only, queries data, and configures busy_timeout")
    func opensWALDatabaseAndSetsBusyTimeout() throws {
        let root = try makeTempDirectory(name: "sqlite space #1 %25 ?q")
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("test.db")
        try createWALDatabase(at: dbURL)

        let db = try #require(SQLiteReadOnlyOpener.open(path: dbURL.path, busyTimeoutMs: 650))
        defer { sqlite3_close(db) }

        #expect(querySingleText(db, sql: "SELECT v FROM t;") == "ok")
        #expect(querySingleInt(db, sql: "PRAGMA busy_timeout;") == 650)
    }

    @Test("Returns nil and does not create a file for non-existent database path")
    func missingPathReturnsNilWithoutCreatingFile() throws {
        let root = try makeTempDirectory(name: "sqlite-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let missingURL = root.appendingPathComponent("does-not-exist.db")
        #expect(SQLiteReadOnlyOpener.open(path: missingURL.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))
    }

    @Test("Reads WAL database in read-only 0500 directory with special characters")
    func readsWALDatabaseInReadOnlyDirectory() throws {
        let root = try makeTempDirectory(name: "sqlite ro #?% space")
        defer {
            _ = chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        let dbURL = root.appendingPathComponent("wal.db")
        try createWALDatabase(at: dbURL)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        #expect(chmod(root.path, 0o500) == 0)

        let db = try #require(SQLiteReadOnlyOpener.open(path: dbURL.path, busyTimeoutMs: 500))
        defer { sqlite3_close(db) }
        #expect(querySingleText(db, sql: "SELECT v FROM t;") == "ok")
    }
}

@Suite("TeamPrefixedAppGroup")
struct TeamPrefixedAppGroupTests {
    @Test("Accepts valid team-prefixed identifiers and rejects unprefixed/template values")
    func validatesTeamPrefix() {
        #expect(AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup("877W5ZP5WY.com.powernotch.app"))
        #expect(AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup("ABCDE12345.com.powernotch.app"))
        #expect(!AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup("com.powernotch.app"))
        #expect(!AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup(""))
        #expect(!AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup("$(TeamIdentifierPrefix)com.powernotch.app"))
        #expect(!AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup("com.example.other"))
    }
}
