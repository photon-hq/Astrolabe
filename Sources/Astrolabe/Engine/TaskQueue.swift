import Foundation

/// Manages in-flight reconciliation tasks with identity-keyed deduplication.
///
/// All public methods are synchronous — safe to call from the sync `tick()`.
/// `enqueue*` methods spawn detached async tasks but return immediately.
/// Tasks self-remove on completion (success or exhausted retries).
public final class TaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [NodeIdentity: Task<Void, Never>] = [:]

    public init() {}

    /// Whether a task is currently in-flight for the given identity.
    public func isInFlight(_ identity: NodeIdentity) -> Bool {
        lock.withLock { tasks[identity] != nil }
    }

    /// Returns the set of all identities currently in the queue.
    public func inFlightIdentities() -> Set<NodeIdentity> {
        lock.withLock { Set(tasks.keys) }
    }

    /// Enqueues a mount task. No-ops if a task for this identity is already in-flight.
    public func enqueueMount(
        identity: NodeIdentity,
        node: TreeNode,
        callbacks: ModifierStore.Callbacks? = nil,
        reconciler: Reconciler,
        payloadStore: PayloadStore
    ) {
        lock.withLock {
            guard tasks[identity] == nil else { return }
            let task = Task { [weak self] in
                await reconciler.mount(node, callbacks: callbacks, payloadStore: payloadStore)
                self?.removeTask(for: identity)
            }
            tasks[identity] = task
        }
    }

    /// Enqueues an unmount task. No-ops if a task for this identity is already in-flight.
    public func enqueueUnmount(
        identity: NodeIdentity,
        reconciler: Reconciler,
        payloadStore: PayloadStore
    ) {
        lock.withLock {
            guard tasks[identity] == nil else { return }
            let task = Task { [weak self] in
                await reconciler.unmount(identity, payloadStore: payloadStore)
                self?.removeTask(for: identity)
            }
            tasks[identity] = task
        }
    }

    private func removeTask(for identity: NodeIdentity) {
        lock.withLock { _ = tasks.removeValue(forKey: identity) }
    }
}
