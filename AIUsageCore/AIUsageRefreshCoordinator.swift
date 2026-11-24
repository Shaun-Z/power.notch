import Foundation

/// All entry points share latest-request-wins semantics. Cancellation is an optimization;
/// request identity is what prevents an uncooperative older operation from publishing.
@MainActor
final class AIUsageRefreshCoordinator<Key: Hashable & Sendable, Value: Sendable> {
    private struct Request {
        let id: UUID
        let task: Task<Value, Never>
    }

    private var requests: [Key: Request] = [:]
    var onChange: ((Set<Key>) -> Void)?
    var refreshingKeys: Set<Key> { Set(requests.keys) }

    func refresh(for key: Key, operation: @escaping @Sendable () async -> Value) async -> Value? {
        requests[key]?.task.cancel()
        let id = UUID()
        let task = Task { await operation() }
        requests[key] = Request(id: id, task: task)
        onChange?(refreshingKeys)

        let value = await task.value
        guard requests[key]?.id == id else { return nil }
        requests.removeValue(forKey: key)
        onChange?(refreshingKeys)
        return task.isCancelled ? nil : value
    }

    func cancel(for key: Key) {
        requests.removeValue(forKey: key)?.task.cancel()
        onChange?(refreshingKeys)
    }
}
