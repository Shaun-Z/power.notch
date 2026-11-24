import Foundation
import Testing
@testable import AIUsageCore

@MainActor
private final class ControlledRequest {
    private var continuation: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func run() async -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            hasStarted = true
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ value: String) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
struct RefreshCoordinatorTests {
    @Test func oldRequestReturningLastCannotOverwriteNewSnapshot() async {
        let coordinator = AIUsageRefreshCoordinator<String, String>()
        let old = ControlledRequest()
        let new = ControlledRequest()
        var snapshot = "INITIAL"
        let oldTask = Task {
            if let value = await coordinator.refresh(for: "codex", operation: { await old.run() }) { snapshot = value }
        }
        await old.waitUntilStarted()
        let newTask = Task {
            if let value = await coordinator.refresh(for: "codex", operation: { await new.run() }) { snapshot = value }
        }
        await new.waitUntilStarted()
        new.finish("NEW")
        await newTask.value
        #expect(snapshot == "NEW")
        #expect(coordinator.refreshingKeys.isEmpty)
        old.finish("OLD") // Deliberately ignores cancellation like an uncooperative dependency.
        await oldTask.value
        #expect(snapshot == "NEW")
        #expect(coordinator.refreshingKeys.isEmpty)
    }

    @Test func oldRequestFinishingFirstDoesNotClearNewRequestState() async {
        let coordinator = AIUsageRefreshCoordinator<String, String>()
        let old = ControlledRequest()
        let new = ControlledRequest()
        let oldTask = Task { await coordinator.refresh(for: "codex", operation: { await old.run() }) }
        await old.waitUntilStarted()
        let newTask = Task { await coordinator.refresh(for: "codex", operation: { await new.run() }) }
        await new.waitUntilStarted()
        old.finish("OLD")
        #expect(await oldTask.value == nil)
        #expect(coordinator.refreshingKeys == ["codex"])
        new.finish("NEW")
        #expect(await newTask.value == "NEW")
        #expect(coordinator.refreshingKeys.isEmpty)
    }

    @Test func providersFinishIndependentlyAndPublishCorrectBusyState() async {
        let coordinator = AIUsageRefreshCoordinator<String, String>()
        var states: [Set<String>] = []
        coordinator.onChange = { states.append($0) }
        let first = ControlledRequest()
        let second = ControlledRequest()
        let firstTask = Task { await coordinator.refresh(for: "codex", operation: { await first.run() }) }
        await first.waitUntilStarted()
        let secondTask = Task { await coordinator.refresh(for: "claude", operation: { await second.run() }) }
        await second.waitUntilStarted()
        first.finish("FIRST")
        #expect(await firstTask.value == "FIRST")
        #expect(coordinator.refreshingKeys == ["claude"])
        second.finish("SECOND")
        #expect(await secondTask.value == "SECOND")
        #expect(states == [["codex"], ["codex", "claude"], ["claude"], []])
    }

    @Test func configurationChangeOrDisableInvalidatesInFlightRequest() async {
        let coordinator = AIUsageRefreshCoordinator<String, String>()
        let request = ControlledRequest()
        let task = Task { await coordinator.refresh(for: "codex", operation: { await request.run() }) }
        await request.waitUntilStarted()
        coordinator.cancel(for: "codex")
        #expect(coordinator.refreshingKeys.isEmpty)
        request.finish("STALE CONFIG")
        #expect(await task.value == nil)
    }
}
