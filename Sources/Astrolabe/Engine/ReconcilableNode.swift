/// A leaf node that knows how to reconcile itself onto the system.
///
/// Each reconcilable type carries its own mount/unmount logic, following SwiftUI's
/// pattern where each primitive owns its lifecycle. The Reconciler delegates
/// to this protocol instead of switching on a central enum.
public protocol ReconcilableNode: Sendable {
    /// Perform the system changes for this node (install, configure, etc.).
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws

    /// Reverse the system changes for this node (uninstall, deactivate, etc.).
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws

    /// A human-readable description for logging.
    var displayName: String { get }
}

extension ReconcilableNode {
    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {}
    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {}
}

/// Shared context passed to all reconciliation operations.
public struct ReconcileContext: Sendable {
    public let payloadStore: PayloadStore

    public init(payloadStore: PayloadStore) {
        self.payloadStore = payloadStore
    }
}
