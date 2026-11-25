//
//  SubprocessAndStreamTests.swift
//  AIUsageCoreTests
//
//  Regression tests for AIUsageCore/SubprocessStreamUtilities.swift:
//  - JSONLinesPipeHandler: single-shot continuation resumption, idempotent close,
//    byte-accurate UTF-8 line framing, malformed-line tolerance, close/write races.
//  - SubprocessTimeoutRunner: exit statuses, prompt timeout + child termination,
//    caller cancellation, missing executable.
//
//  Determinism notes:
//  - All waits are bounded by `pollUntil` / explicit deadlines, so a broken
//    implementation fails instead of hanging the suite.
//  - Child-process tests use short-lived binaries (/usr/bin/true|false, /bin/sleep)
//    and marker files inside a unique temporary directory.
//

import Foundation
import Testing
@testable import AIUsageCore

// =========================================================================== //
// MARK: - ADAPTER: the only place that touches the production API surface.
// Adjust these five helpers to the exact signatures in
// AIUsageCore/SubprocessStreamUtilities.swift; every test below stays unchanged.
// =========================================================================== //

private func makeHandler() async -> JSONLinesPipeHandler {
    JSONLinesPipeHandler()
}

// `Pipe` is not Sendable, so the intended API exposes `getPipe()` nonisolated.
private func writeEnd(of handler: JSONLinesPipeHandler) -> FileHandle {
    handler.getPipe().fileHandleForWriting
}

private func closeHandler(_ handler: JSONLinesPipeHandler) async {
    await handler.close()
}

@discardableResult
private func runSubprocess(
    _ executable: String,
    _ arguments: [String],
    timeout: Duration
) async throws -> Int32 {
    try await SubprocessTimeoutRunner.run(
        executableURL: URL(fileURLWithPath: executable),
        arguments: arguments,
        timeout: timeout
    )
}

// =========================================================================== //
// MARK: - Harness
// =========================================================================== //

private struct StreamLine: Decodable, Sendable, Equatable {
    let id: Int
    let text: String
}

private actor LineSink<Element: Sendable> {
    private var storage: [Element] = []

    func append(_ element: Element) {
        storage.append(element)
    }

    var elements: [Element] { storage }
    var count: Int { storage.count }
}

private actor CompletionFlag {
    private var done = false
    func mark() { done = true }
    var isDone: Bool { done }
}

/// Bounded poll: returns false instead of blocking forever when the code under test never resumes.
private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

@discardableResult
private func startReader(
    _ handler: JSONLinesPipeHandler,
    sink: LineSink<StreamLine>,
    flag: CompletionFlag
) -> Task<Void, Never> {
    Task {
        await handler.readJSONLines(as: StreamLine.self) { line in
            await sink.append(line)
        }
        await flag.mark()
    }
}

private func write(_ data: Data, to handle: FileHandle) {
    try? handle.write(contentsOf: data)
}

private func write(_ string: String, to handle: FileHandle) {
    write(Data(string.utf8), to: handle)
}

private func lineData(id: Int, text: String) -> Data {
    Data(#"{"id":\#(id),"text":"\#(text)"}"#.utf8)
}

private func terminatedLine(id: Int, text: String) -> Data {
    var data = lineData(id: id, text: text)
    data.append(0x0A)
    return data
}

/// Waits for the reader to finish, then returns what it collected.
private func drain(
    _ reader: Task<Void, Never>,
    sink: LineSink<StreamLine>,
    flag: CompletionFlag,
    timeout: Duration = .seconds(2)
) async -> [StreamLine]? {
    let finished = await pollUntil(timeout: timeout) { await flag.isDone }
    if !finished {
        reader.cancel()
        return nil
    }
    _ = await reader.value
    return await sink.elements
}

/// Waits until the reader has published `expected` records (bounded), so framing tests
/// do not race `close()` against in-flight pipe delivery.
private func waitForRecords(
    _ expected: Int,
    sink: LineSink<StreamLine>,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await pollUntil(timeout: timeout) { await sink.count >= expected }
}


/// True while any process matches `pgrep -f <argument>`; used to prove a timed-out/cancelled child is
/// reaped. Callers pass a unique per-run temp path, so nothing else on the machine can match.
private func processExists(matching argument: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", argument]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0
}

private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("powernotch-stream-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// =========================================================================== //
// MARK: - Line framing (byte-accurate UTF-8)
// =========================================================================== //

@Suite("JSONLinesPipeHandler framing")
struct JSONLinesPipeHandlerFramingTests {

    @Test("Multiple JSON lines in one write are all delivered in order")
    func multipleLinesInSingleWrite() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = Data()
        payload.append(terminatedLine(id: 1, text: "first"))
        payload.append(terminatedLine(id: 2, text: "second"))
        payload.append(terminatedLine(id: 3, text: "third"))
        write(payload, to: handle)
        #expect(await waitForRecords(3, sink: sink), "reader must deliver all three records")

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1, 2, 3])
        #expect(lines.map(\.text) == ["first", "second", "third"])
    }

    @Test("A single line split across many tiny writes is reassembled")
    func lineSplitAcrossTinyWrites() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        let payload = terminatedLine(id: 7, text: "reassembled across writes")
        for byte in payload {
            write(Data([byte]), to: handle)
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await waitForRecords(1, sink: sink), "byte-by-byte writes must still yield one record")

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.count == 1)
        #expect(lines.first?.id == 7)
        #expect(lines.first?.text == "reassembled across writes")
    }

    @Test("Multi-byte UTF-8 codepoints split mid-codepoint decode intact")
    func multibyteUTF8SplitMidCodepoint() async throws {
        let text = "🎵日本語😀"
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        let payload = terminatedLine(id: 42, text: text)
        let string = String(decoding: payload, as: UTF8.self)
        // Cut 1 byte into the 4-byte "🎵" scalar: guaranteed invalid UTF-8 on its own.
        let emojiStart = try #require(string.range(of: "🎵")).lowerBound
        let cut = string[..<emojiStart].utf8.count + 1
        #expect(cut < payload.count)

        write(payload.prefix(cut), to: handle)
        try? await Task.sleep(for: .milliseconds(20))
        write(payload.suffix(from: cut), to: handle)
        #expect(await waitForRecords(1, sink: sink), "split codepoint must still yield the record")

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.count == 1, "a split codepoint must not drop or duplicate the line")
        #expect(lines.first?.text == text)
    }

    @Test("Every possible mid-codepoint split point decodes intact", arguments: [1, 2, 3])
    func byteByByteSplitOffsets(offset: Int) async throws {
        let text = "日本語😀🎵"
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        let payload = terminatedLine(id: offset, text: text)
        let string = String(decoding: payload, as: UTF8.self)
        let emojiStart = try #require(string.range(of: "😀")).lowerBound
        let cut = string[..<emojiStart].utf8.count + offset
        write(payload.prefix(cut), to: handle)
        write(payload.suffix(from: cut), to: handle)
        #expect(await waitForRecords(1, sink: sink), "split at +\(offset) must still yield the record")

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.first?.text == text)
    }

    @Test("CRLF terminators and blank lines are handled cleanly")
    func crlfAndBlankLines() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = Data()
        payload.append(lineData(id: 1, text: "one"))
        payload.append(contentsOf: [0x0D, 0x0A])
        payload.append(contentsOf: [0x0A])
        payload.append(contentsOf: [0x0D, 0x0A])
        payload.append(lineData(id: 2, text: "two"))
        payload.append(0x0A)
        write(payload, to: handle)
        #expect(await waitForRecords(2, sink: sink), "both real lines must arrive before close")

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1, 2], "blank lines must not produce phantom records")
    }

    @Test("A malformed line is skipped without aborting later valid lines")
    func malformedLineSkipped() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = Data()
        payload.append(Data("{not json}\n".utf8))
        payload.append(terminatedLine(id: 2, text: "survivor"))
        payload.append(Data("{\"id\":\"wrong-type\"}\n".utf8))
        payload.append(terminatedLine(id: 4, text: "also survives"))
        write(payload, to: handle)
        #expect(await waitForRecords(2, sink: sink), "valid lines around a malformed one must arrive")

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [2, 4])
    }

    // Trailing-line EOF-flush cases. Determinism note: the implementation flushes the handler's
    // *buffer* at EOF but discards OS bytes it has not read yet, so a tail written in its own
    // chunk cannot be distinguished from a dropped chunk without low-level FIONREAD
    // introspection (not importable on this SDK). Each case therefore ships the unterminated
    // tail in the same write as a newline-terminated sentinel, and waits for the sentinel to be
    // delivered — which proves the tail bytes reached the handler buffer before close().

    @Test("A buffered trailing line without newline is flushed when the stream closes")
    func unterminatedTrailingLineFlushedOnClose() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = terminatedLine(id: 1, text: "sentinel")
        payload.append(lineData(id: 9, text: "no trailing newline"))
        write(payload, to: handle)
        #expect(await waitForRecords(1, sink: sink), "sentinel must arrive before close()")
        #expect(await sink.count == 1, "the unterminated tail must not be emitted before EOF")
        try? await Task.sleep(for: .milliseconds(50))
        await closeHandler(handler)

        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1, 9], "the final record must not be lost at EOF")
        #expect(lines.last?.text == "no trailing newline")
    }

    @Test("A buffered trailing line ending in CR without LF is flushed with the CR stripped")
    func unterminatedTrailingLineWithCRFlushed() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = terminatedLine(id: 1, text: "sentinel")
        payload.append(lineData(id: 11, text: "carriage return at EOF"))
        payload.append(0x0D)  // CR, but no LF before close
        write(payload, to: handle)
        #expect(await waitForRecords(1, sink: sink))
        try? await Task.sleep(for: .milliseconds(50))
        await closeHandler(handler)

        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1, 11], "the flushed record must decode after CR stripping")
        #expect(lines.last?.text == "carriage return at EOF")
    }

    @Test("Truncated partial JSON at close is discarded cleanly")
    func truncatedPartialJSONDiscarded() async throws {
        // A truncated trailing record must fail decoding once and be ignored — no crash,
        // no phantom record, and the reader must still terminate.
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = terminatedLine(id: 1, text: "complete")
        payload.append(Data(#"{"id":2,"text":"trunc"#.utf8))  // no closing brace, no newline
        write(payload, to: handle)
        #expect(await waitForRecords(1, sink: sink))
        try? await Task.sleep(for: .milliseconds(50))
        await closeHandler(handler)

        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1],
                "a truncated tail must be ignored, not surfaced or duplicated")
    }

    @Test("Cancellation between reads still flushes the buffered tail at loop exit")
    func cancellationStillFlushesTail() async throws {
        // Buffered data is flushed once upon EOF / loop exit. Cancellation is also a loop exit,
        // so a buffered valid tail must still be delivered when the consumer is cancelled
        // while parked in readData() and a later close() wakes it.
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = terminatedLine(id: 1, text: "sentinel")
        payload.append(lineData(id: 9, text: "tail buffered at cancellation"))
        write(payload, to: handle)
        #expect(await waitForRecords(1, sink: sink))
        try? await Task.sleep(for: .milliseconds(50))

        reader.cancel()
        await closeHandler(handler)

        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1, 9],
                "a cancelled consumer must still receive the buffered valid tail")
    }

    @Test("Complete lines followed by an unterminated final line all arrive")
    func completeLinesPlusUnterminatedTail() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = Data()
        payload.append(terminatedLine(id: 1, text: "newline terminated"))
        payload.append(terminatedLine(id: 2, text: "also terminated"))
        payload.append(lineData(id: 3, text: "flushed at EOF"))
        write(payload, to: handle)
        #expect(await waitForRecords(2, sink: sink))
        try? await Task.sleep(for: .milliseconds(50))

        await closeHandler(handler)
        let lines = try #require(await drain(reader, sink: sink, flag: flag))
        #expect(lines.map(\.id) == [1, 2, 3], "EOF flush must not drop or duplicate the tail")
    }
}

// =========================================================================== //
// MARK: - Lifecycle: close(), continuation safety, races
// =========================================================================== //

@Suite("JSONLinesPipeHandler lifecycle")
struct JSONLinesPipeHandlerLifecycleTests {

    @Test("close() resumes a reader suspended on an idle open pipe")
    func closeWhileSuspendedReturnsPromptly() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        // Let the reader park on the idle pipe (no data written).
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await flag.isDone == false, "reader must be suspended before close()")

        let start = ContinuousClock.now
        await closeHandler(handler)
        let finished = await pollUntil(timeout: .seconds(2)) { await flag.isDone }
        let elapsed = ContinuousClock.now - start

        #expect(finished, "close() must resume the suspended continuation")
        #expect(elapsed < .seconds(1), "close() must return promptly, took \(elapsed)")
        reader.cancel()
        _ = await reader.value
        #expect(await sink.count == 0)
        _ = handle
    }

    @Test("close() is idempotent")
    func closeIsIdempotent() async throws {
        let handler = await makeHandler()
        _ = writeEnd(of: handler)
        await closeHandler(handler)
        await closeHandler(handler)
        await closeHandler(handler)
        // Surviving three closes without a crash or hang is the assertion.
        #expect(Bool(true))
    }

    @Test("Reading after close() returns immediately")
    func readAfterCloseReturnsImmediately() async throws {
        let handler = await makeHandler()
        _ = writeEnd(of: handler)
        await closeHandler(handler)

        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)
        let finished = await pollUntil(timeout: .seconds(1)) { await flag.isDone }
        #expect(finished, "readJSONLines after close() must not block")
        _ = await drain(reader, sink: sink, flag: flag)
        #expect(await sink.count == 0)
    }

    @Test("Concurrent close() calls resume a single reader exactly once")
    func concurrentCloseResumesOnce() async throws {
        let handler = await makeHandler()
        _ = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        try? await Task.sleep(for: .milliseconds(50))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await closeHandler(handler) }
            }
        }
        let finished = await pollUntil(timeout: .seconds(2)) { await flag.isDone }
        #expect(finished)
        _ = await drain(reader, sink: sink, flag: flag)
    }

    @Test("close() racing rapid writes never crashes or hangs", arguments: 0..<15)
    func closeRacingWritesStress(iteration: Int) async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        let writer = Task {
            for index in 0..<25 {
                write(terminatedLine(id: index, text: "iteration \(iteration)"), to: handle)
                await Task.yield()
            }
        }
        try? await Task.sleep(for: .milliseconds(1))
        await closeHandler(handler)
        writer.cancel()
        _ = await writer.value

        let finished = await pollUntil(timeout: .seconds(2)) { await flag.isDone }
        #expect(finished, "iteration \(iteration): reader must terminate after close()")
        _ = await drain(reader, sink: sink, flag: flag)
        let count = await sink.count
        #expect(count >= 0 && count <= 25, "iteration \(iteration): unexpected record count \(count)")
    }

    @Test("Cancelling reader Task without calling close() wakes readData() promptly and flushes tail")
    func taskCancellationWithoutExplicitCloseWakesPromptly() async throws {
        let handler = await makeHandler()
        let handle = writeEnd(of: handler)
        let sink = LineSink<StreamLine>()
        let flag = CompletionFlag()
        let reader = startReader(handler, sink: sink, flag: flag)

        var payload = terminatedLine(id: 1, text: "sentinel")
        payload.append(lineData(id: 2, text: "buffered tail"))
        write(payload, to: handle)
        #expect(await waitForRecords(1, sink: sink))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await flag.isDone == false, "reader must still be suspended on the idle pipe")

        let start = ContinuousClock.now
        reader.cancel()
        let lines = try #require(await drain(reader, sink: sink, flag: flag, timeout: .seconds(1.5)))
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(1), "Task cancellation alone must wake readData() promptly, took \(elapsed)")
        #expect(lines.map(\.id) == [1, 2], "buffered tail must still flush on task-only cancellation")
        _ = handle
    }
}

// =========================================================================== //
// MARK: - SubprocessTimeoutRunner
// =========================================================================== //

@Suite("Subprocess timeout runner")
struct SubprocessTimeoutRunnerTests {

    @Test("/usr/bin/true reports exit status 0")
    func trueReturnsZero() async throws {
        let status = try await runSubprocess("/usr/bin/true", [], timeout: .seconds(5))
        #expect(status == 0)
    }

    @Test("/usr/bin/false reports exit status 1")
    func falseReturnsOne() async throws {
        let status = try await runSubprocess("/usr/bin/false", [], timeout: .seconds(5))
        #expect(status == 1)
    }

    @Test("Timeout terminates the direct child before its post-sleep side effect")
    func timeoutTerminatesDirectChild() async throws {
        // Only the direct child process is terminated (process.terminate(), no process groups).
        // Spawn a single interpreter process (no `/bin/sh -c` wrapper, whose WCE signal deferral
        // would confound the result) that would create the marker only if it survived the sleep.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("perl-child-finished-\(UUID().uuidString)")

        let started = ContinuousClock.now
        var thrown: Error?
        do {
            _ = try await runSubprocess(
                "/usr/bin/perl",
                ["-e", "$SIG{TERM}=sub{exit 143}; sleep 5; open my $f, \">\", $ARGV[0]; close $f",
                 marker.path],
                timeout: .milliseconds(150)
            )
            Issue.record("expected a timeout error, got a normal return")
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started

        #expect(thrown is SubprocessTimeoutError, "expected SubprocessTimeoutError, got \(String(describing: thrown))")
        #expect(thrown as? SubprocessTimeoutError == .timedOut,
                "timeout must be reported as .timedOut, not as an execution failure")
        #expect(elapsed < .milliseconds(900), "timeout must fire promptly, took \(elapsed)")

        // The direct child must be gone: nothing may still match its unique marker argument.
        let reaped = await pollUntil(timeout: .seconds(1.5)) { !processExists(matching: marker.path) }
        #expect(reaped, "timed-out direct child must be terminated")

        // And its post-sleep side effect must never run (would appear at t≈5s).
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "the timed-out child's post-sleep side effect must never execute")
    }

    @Test("/bin/sleep is terminated when its timeout fires (single-process direct child)")
    func directSleepTimeoutKillsChild() async throws {
        let started = ContinuousClock.now
        var thrown: Error?
        do {
            _ = try await runSubprocess("/bin/sleep", ["3.7"], timeout: .milliseconds(150))
            Issue.record("expected a timeout error from /bin/sleep")
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started

        #expect(thrown as? SubprocessTimeoutError == .timedOut,
                "expected .timedOut, got \(String(describing: thrown))")
        #expect(elapsed < .milliseconds(900), "timeout must fire promptly, took \(elapsed)")
        let reaped = await pollUntil(timeout: .seconds(1.5)) { !processExists(matching: "sleep 3.7") }
        #expect(reaped, "the timed-out /bin/sleep process must be terminated")
    }

    @Test("Caller cancellation terminates the child promptly")
    func cancellationTerminatesChild() async throws {
        // Cancellation terminates the direct child; single interpreter process, no shell wrapper.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("cancel-finished-\(UUID().uuidString)")

        let task = Task {
            try await runSubprocess(
                "/usr/bin/perl",
                ["-e", "$SIG{TERM}=sub{exit 143}; sleep 2; open my $f, \">\", $ARGV[0]; close $f",
                 marker.path],
                timeout: .seconds(10)
            )
        }
        try? await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(1.5), "cancellation must not wait for the child, took \(elapsed)")
        let reaped = await pollUntil(timeout: .seconds(1.5)) { !processExists(matching: marker.path) }
        #expect(reaped, "cancelled direct child must be terminated")
        try? await Task.sleep(for: .milliseconds(2300))
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "a cancelled child must not reach its post-sleep side effect")
    }

    @Test("Missing executable reports an execution failure, not a timeout")
    func missingExecutableThrowsExecutionFailure() async throws {
        var thrown: Error?
        do {
            _ = try await runSubprocess("/nonexistent/path/powernotch-xyz", [], timeout: .milliseconds(500))
            Issue.record("expected an execution failure")
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(!(error is SubprocessTimeoutError && (error as? SubprocessTimeoutError) == .timedOut),
                "a missing binary must not be reported as a timeout: \(error)")
        if let subprocessError = error as? SubprocessTimeoutError {
            #expect(subprocessError == .executionFailed,
                    "a spawn failure should surface as .executionFailed, got \(subprocessError)")
        }
    }

    @Test("Fast child returns well before its timeout budget")
    func fastChildBeatsTimeout() async throws {
        let start = ContinuousClock.now
        let status = try await runSubprocess("/bin/sh", ["-c", "exit 3"], timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start
        #expect(status == 3)
        #expect(elapsed < .seconds(2), "a fast child must not wait for the timeout, took \(elapsed)")
    }
}

// =========================================================================== //
// MARK: - SubprocessZipArchiver
// =========================================================================== //

@Suite("SubprocessZipArchiver")
struct SubprocessZipArchiverTests {

    private func listZipEntries(at archiveURL: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archiveURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test("Multi-item archive isolates staging so an input named Archive.zip never collides with output")
    func multiItemInputNamedArchiveZipDoesNotCollide() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDir = root.appendingPathComponent("inputs", isDirectory: true)
        let workingDir = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let existingZipInput = inputDir.appendingPathComponent("Archive.zip")
        let notesInput = inputDir.appendingPathComponent("notes.txt")
        let originalPayload = Data("inner-archive-payload-bytes".utf8)
        try originalPayload.write(to: existingZipInput)
        try Data("hello shelf".utf8).write(to: notesInput)

        let archiveURL = try #require(
            await SubprocessZipArchiver.createArchive(
                from: [existingZipInput, notesInput],
                workingDirectory: workingDir,
                suggestedName: nil
            )
        )

        #expect(archiveURL.lastPathComponent == "Archive.zip")
        let remainingInWorkingDir = try FileManager.default.contentsOfDirectory(atPath: workingDir.path)
        #expect(remainingInWorkingDir == ["Archive.zip"], "staging items/ directory must be removed after zip")

        let entries = try listZipEntries(at: archiveURL)
        #expect(entries.contains("Archive.zip"))
        #expect(entries.contains("notes.txt"))

        let extractDir = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archiveURL.path, "-d", extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        let extractedBytes = try Data(contentsOf: extractDir.appendingPathComponent("Archive.zip"))
        #expect(extractedBytes == originalPayload)
    }
}
