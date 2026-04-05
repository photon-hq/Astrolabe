import Foundation

/// Manages in-flight reconciliation tasks with identity-keyed deduplication.
///
/// All public methods are synchronous — safe to call from the sync `tick()`.
/// `enqueue*` methods spawn detached async tasks but return immediately.
/// Tasks self-remove on completion (success or exhausted retries).
public final class TaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [NodeIdentity: Task<Void, Never>] = [:]

    /// Pending priority groups waiting to be started (mount).
    private var pendingMountGroups: [([PrioritizedWork], Reconciler, PayloadStore)] = []
    private var mountGroupRemaining = 0

    /// Pending priority groups waiting to be started (unmount).
    private var pendingUnmountGroups: [([PrioritizedWork], Reconciler, PayloadStore)] = []
    private var unmountGroupRemaining = 0

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
        node: TreeNode,
        callbacks: ModifierStore.Callbacks? = nil,
        reconciler: Reconciler,
        payloadStore: PayloadStore
    ) {
        lock.withLock {
            guard tasks[identity] == nil else { return }
            let task = Task { [weak self] in
                await reconciler.unmount(node, callbacks: callbacks, payloadStore: payloadStore)
                self?.removeTask(for: identity)
            }
            tasks[identity] = task
        }
    }

    /// A unit of mount/unmount work with its priority.
    public struct PrioritizedWork: Sendable {
        public let identity: NodeIdentity
        public let node: TreeNode
        public let callbacks: ModifierStore.Callbacks?
        public let priority: Int
    }

    /// Enqueues mount tasks grouped by priority. Tasks within the same priority
    /// run in parallel. Priority groups execute sequentially (lowest first).
    /// All identities are registered as in-flight immediately.
    public func enqueuePriorityMounts(
        groups: [[PrioritizedWork]],
        reconciler: Reconciler,
        payloadStore: PayloadStore
    ) {
        lock.withLock {
            let filteredGroups = groups.map { group in
                group.filter { tasks[$0.identity] == nil }
            }.filter { !$0.isEmpty }

            guard !filteredGroups.isEmpty else { return }

            // Register all identities as in-flight with a placeholder task
            // so subsequent ticks skip them.
            let placeholder = Task<Void, Never> {}
            for work in filteredGroups.flatMap({ $0 }) {
                tasks[work.identity] = placeholder
            }

            // Queue all groups, start the first one
            pendingMountGroups = filteredGroups.map { ($0, reconciler, payloadStore) }
            _startNextMountGroup()
        }
    }

    /// Enqueues unmount tasks grouped by priority. Tasks within the same priority
    /// run in parallel. Priority groups execute sequentially (highest first).
    /// All identities are registered as in-flight immediately.
    public func enqueuePriorityUnmounts(
        groups: [[PrioritizedWork]],
        reconciler: Reconciler,
        payloadStore: PayloadStore
    ) {
        lock.withLock {
            let filteredGroups = groups.map { group in
                group.filter { tasks[$0.identity] == nil }
            }.filter { !$0.isEmpty }

            guard !filteredGroups.isEmpty else { return }

            let placeholder = Task<Void, Never> {}
            for work in filteredGroups.flatMap({ $0 }) {
                tasks[work.identity] = placeholder
            }

            pendingUnmountGroups = filteredGroups.map { ($0, reconciler, payloadStore) }
            _startNextUnmountGroup()
        }
    }

    // MARK: - Private

    /// Starts the next pending mount group. Must be called with lock held.
    private func _startNextMountGroup() {
        guard !pendingMountGroups.isEmpty else { return }
        let (group, reconciler, payloadStore) = pendingMountGroups.removeFirst()
        mountGroupRemaining = group.count

        for work in group {
            let task = Task { [weak self] in
                await reconciler.mount(work.node, callbacks: work.callbacks, payloadStore: payloadStore)
                self?.mountTaskCompleted(work.identity)
            }
            tasks[work.identity] = task
        }
    }

    /// Called when a single mount task in the current group finishes.
    private func mountTaskCompleted(_ identity: NodeIdentity) {
        lock.withLock {
            _ = tasks.removeValue(forKey: identity)
            mountGroupRemaining -= 1
            if mountGroupRemaining == 0 {
                _startNextMountGroup()
            }
        }
    }

    /// Starts the next pending unmount group. Must be called with lock held.
    private func _startNextUnmountGroup() {
        guard !pendingUnmountGroups.isEmpty else { return }
        let (group, reconciler, payloadStore) = pendingUnmountGroups.removeFirst()
        unmountGroupRemaining = group.count

        for work in group {
            let task = Task { [weak self] in
                await reconciler.unmount(work.node, callbacks: work.callbacks, payloadStore: payloadStore)
                self?.unmountTaskCompleted(work.identity)
            }
            tasks[work.identity] = task
        }
    }

    /// Called when a single unmount task in the current group finishes.
    private func unmountTaskCompleted(_ identity: NodeIdentity) {
        lock.withLock {
            _ = tasks.removeValue(forKey: identity)
            unmountGroupRemaining -= 1
            if unmountGroupRemaining == 0 {
                _startNextUnmountGroup()
            }
        }
    }

    private func removeTask(for identity: NodeIdentity) {
        lock.withLock { _ = tasks.removeValue(forKey: identity) }
    }
}
