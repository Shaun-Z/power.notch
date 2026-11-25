import Foundation
import Darwin

/// A single-reader pipe with idempotent EOF shutdown and byte-oriented framing.
public actor JSONLinesPipeHandler {
    private enum State {
        case idle
        case waiting(Int, CheckedContinuation<Data, Error>)
        case closed
    }
    public enum ReadError: Error { case concurrentRead }
    nonisolated private let pipe = Pipe()
    private var state: State = .idle
    private var generation = 0
    private var buffer = Data()

    public init() {
        let rfd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(rfd, F_GETFL)
        if flags >= 0 { _ = fcntl(rfd, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    public nonisolated func getPipe() -> Pipe { pipe }

    public func readData() async throws -> Data {
        if Task.isCancelled { close(); return Data() }
        switch state {
        case .closed: return Data()
        case .waiting: throw ReadError.concurrentRead
        case .idle: break
        }
        if let chunk = try readChunk() { return chunk }
        generation += 1
        let token = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    close()
                    continuation.resume(returning: Data())
                    return
                }
                state = .waiting(token, continuation)
                armReadability(token: token)
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func armReadability(token: Int) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
            Task { await self?.readable(token: token) }
        }
    }

    /// nil means the nonblocking descriptor has no bytes ready yet.
    private func readChunk() throws -> Data? {
        if case .closed = state { return Data() }
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { close(); return Data() }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK { return nil }
            close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private func readable(token: Int) {
        guard case .waiting(let current, let continuation) = state, current == token else { return }
        pipe.fileHandleForReading.readabilityHandler = nil
        do {
            // Move ownership locally before readChunk can close on EOF/error.
            state = .idle
            if let data = try readChunk() {
                continuation.resume(returning: data)
            } else {
                state = .waiting(current, continuation)
                armReadability(token: current)
            }
        } catch {
            close()
            continuation.resume(throwing: error)
        }
    }

    public func readJSONLines<T: Decodable & Sendable>(
        as type: T.Type, onLine: @Sendable (T) async -> Void
    ) async {
        do {
            while !Task.isCancelled {
                let data = try await readData()
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    await deliver(line, as: type, onLine: onLine)
                }
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
        let tail = buffer
        buffer.removeAll()
        await deliver(tail, as: type, onLine: onLine)
    }

    private func deliver<T: Decodable & Sendable>(
        _ data: Data, as type: T.Type, onLine: @Sendable (T) async -> Void
    ) async {
        var line = data
        if line.last == 0x0D { line.removeLast() }
        if !line.isEmpty, let value = try? JSONDecoder().decode(T.self, from: line) {
            await onLine(value)
        }
    }

    public func close() {
        if case .closed = state { return }
        let previous = state
        state = .closed
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        if case .waiting(_, let continuation) = previous { continuation.resume(returning: Data()) }
    }
}

public enum SubprocessZipArchiver {
    public static func createArchive(
        from urls: [URL], workingDirectory workingDir: URL, suggestedName: String? = nil
    ) async -> URL? {
        let fm = FileManager.default
        var archiveCreated = false
        defer {
            if !archiveCreated { try? fm.removeItem(at: workingDir) }
        }
        guard !urls.isEmpty else { return nil }

        if urls.count == 1, let source = urls.first {
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let baseName = source.lastPathComponent
            let archiveURL = workingDir.appendingPathComponent("\(baseName).zip")
            guard await runZip(
                arguments: [isDirectory ? "-r" : "-j", "-q", archiveURL.path, "--", baseName],
                currentDirectory: source.deletingLastPathComponent()
            ) else { return nil }
            archiveCreated = true
            return archiveURL
        }

        let stagingDir = workingDir.appendingPathComponent("items", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            var copiedCount = 0
            for source in urls {
                var destination = stagingDir.appendingPathComponent(source.lastPathComponent)
                if fm.fileExists(atPath: destination.path) {
                    destination = stagingDir.appendingPathComponent("\(UUID().uuidString)_\(source.lastPathComponent)")
                }
                do {
                    try fm.copyItem(at: source, to: destination)
                    copiedCount += 1
                } catch {
                    print("Failed to stage zip input: \(error)")
                }
            }
            guard copiedCount > 0 else { return nil }
            let archiveURL = workingDir.appendingPathComponent(suggestedName ?? "Archive.zip")
            guard await runZip(
                arguments: ["-r", "-q", archiveURL.path, "--", "."],
                currentDirectory: stagingDir
            ) else { return nil }
            try fm.removeItem(at: stagingDir)
            archiveCreated = true
            return archiveURL
        } catch {
            print("Failed to create zip archive: \(error)")
            return nil
        }
    }

    private static func runZip(arguments: [String], currentDirectory: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                print("Failed to run zip: \(error)")
                continuation.resume(returning: false)
            }
        }
    }
}

public enum SubprocessTimeoutError: Error, Equatable { case executionFailed, timedOut }

/// Serializes launch/cancellation and transfers each continuation exactly once.
private final class SubprocessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var cancelled = false

    func start(executableURL: URL, arguments: [String], continuation: CheckedContinuation<Int32, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        process.executableURL = executableURL
        process.arguments = arguments
        process.terminationHandler = { [self] process in finish(.success(process.terminationStatus)) }
        do {
            try process.run()
            lock.unlock()
        } catch {
            process.terminationHandler = nil
            lock.unlock()
            finish(.failure(SubprocessTimeoutError.executionFailed))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Int32, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        process.terminationHandler = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

public enum SubprocessTimeoutRunner {
    public static func run(executableURL: URL, arguments: [String], timeout: Duration) async throws -> Int32 {
        let execution = SubprocessExecution()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: Int32.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation {
                            execution.start(executableURL: executableURL, arguments: arguments, continuation: $0)
                        }
                    } onCancel: { execution.cancel() }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SubprocessTimeoutError.timedOut
                }
                do {
                    guard let status = try await group.next() else { throw CancellationError() }
                    return status
                } catch {
                    group.cancelAll()
                    execution.cancel()
                    throw error
                }
            }
        } onCancel: { execution.cancel() }
    }
}
