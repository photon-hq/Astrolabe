/// Reconciles a set of diff actions in parallel.
///
/// All leaf node reconciliation runs concurrently. Errors are caught per-node
/// and never crash the daemon.
public struct ReconciliationEngine: Sendable {
    private let reconciler: Reconciler
    private let payloadStore: PayloadStore

    public init(reconciler: Reconciler = Reconciler(), payloadStore: PayloadStore) {
        self.reconciler = reconciler
        self.payloadStore = payloadStore
    }

    /// Reconciles all actions in parallel, returning updated statuses.
    public func reconcile(_ actions: [DiffAction]) async -> [NodeIdentity: NodeStatus] {
        var statuses: [NodeIdentity: NodeStatus] = [:]

        await withTaskGroup(of: (NodeIdentity, NodeStatus).self) { group in
            for action in actions {
                group.addTask {
                    switch action {
                    case .install(let node):
                        await reconciler.reconcile(action, payloadStore: payloadStore)
                        // Check if payload was written (install succeeded)
                        let succeeded = await payloadStore.record(for: node.identity) != nil
                        return (node.identity, succeeded ? .applied : .pending)

                    case .uninstall(let identity):
                        await reconciler.reconcile(action, payloadStore: payloadStore)
                        return (identity, .pending) // removed from tree

                    case .unchanged(let node):
                        return (node.identity, node.status)
                    }
                }
            }

            for await (identity, status) in group {
                statuses[identity] = status
            }
        }

        return statuses
    }
}
