import Foundation
import Security
import Darwin

public enum KeychainBackendReadResult: Equatable, Sendable {
    case available(String?), unavailable(OSStatus)
}
public enum KeychainBackendWriteResult: Equatable, Sendable {
    case available, unavailable(OSStatus)
}
public protocol SecretKeychainBackend: Sendable {
    func read(account: String) -> KeychainBackendReadResult
    func write(_ value: String?, account: String) -> KeychainBackendWriteResult
}

public struct DataProtectionKeychainBackend: SecretKeychainBackend {
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.powernotch.app.ai-usage",
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }
    public func read(account: String) -> KeychainBackendReadResult {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .available(nil) }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return .unavailable(errSecDecode)
        }
        return .available(value)
    }
    public func write(_ value: String?, account: String) -> KeychainBackendWriteResult {
        let query = query(account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound ? .available : .unavailable(status)
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        return status == errSecSuccess ? .available : .unavailable(status)
    }
}

/// File fallback for unsigned builds. Every operation is serialized and refuses symlinks.
public final class POSIXAtomicSecretFileStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    private func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent().path
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT else { throw failure() }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw CocoaError(.fileReadNoPermission)
        }
        if info.st_mode & 0o777 != 0o700 {
            guard chmod(directory, 0o700) == 0 else { throw failure() }
        }
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    private func validateTarget() throws -> Bool {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw failure()
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw CocoaError(.fileReadNoPermission)
        }
        return true
    }
    private func load() throws -> [String: String] {
        try prepareDirectory()
        guard try validateTarget() else { return [:] }
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw failure() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure()
            }
            data.append(contentsOf: bytes.prefix(count))
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    private func save(_ map: [String: String]) throws {
        try prepareDirectory()
        _ = try validateTarget()
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".ai-usage-secrets.\(UUID().uuidString).tmp").path
        let fd = Darwin.open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure() }
        var isOpen = true
        defer {
            if isOpen { Darwin.close(fd) }
            unlink(temporary)
        }
        let data = try JSONEncoder().encode(map)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure() }
        let status = Darwin.close(fd)
        isOpen = false
        guard status == 0 else { throw failure() }
        guard Darwin.rename(temporary, fileURL.path) == 0 else { throw failure() }
    }
    public func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        do { return try load()[account] }
        catch { NSLog("Secret file read failed: %@", error.localizedDescription); return nil }
    }
    public func write(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            var map = try load()
            map[account] = value
            try save(map)
        } catch { NSLog("Secret file write failed: %@", error.localizedDescription) }
    }
    public func remove(account: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            var map = try load()
            guard map.removeValue(forKey: account) != nil else { return }
            try save(map)
        } catch { NSLog("Secret file removal failed: %@", error.localizedDescription) }
    }
}

public final class DualTrackSecretStore: @unchecked Sendable {
    private let lock = NSLock()
    private let keychain: any SecretKeychainBackend
    private let fileStore: POSIXAtomicSecretFileStore
    public init(keychain: any SecretKeychainBackend = DataProtectionKeychainBackend(), fileStore: POSIXAtomicSecretFileStore) {
        self.keychain = keychain
        self.fileStore = fileStore
    }
    public func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch keychain.read(account: account) {
        case .available(let value?):
            fileStore.remove(account: account)
            return value
        case .available(nil):
            guard let legacy = fileStore.read(account: account) else { return nil }
            if keychain.write(legacy, account: account) == .available { fileStore.remove(account: account) }
            return legacy
        case .unavailable: return fileStore.read(account: account)
        }
    }
    public func write(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if keychain.write(trimmed.isEmpty ? nil : trimmed, account: account) == .available {
            fileStore.remove(account: account)
        } else if trimmed.isEmpty {
            fileStore.remove(account: account)
        } else {
            fileStore.write(trimmed, account: account)
        }
    }
}
