/// A leaf node that knows how to reconcile itself onto the system.
///
/// Each reconcilable type carries its own mount logic, following SwiftUI's
/// pattern where each primitive is its own behavior. The Reconciler delegates
/// to this protocol instead of switching on a central enum.
public protocol ReconcilableNode: Sendable {
    /// Perform the system changes for this node (install, configure, etc.).
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws

    /// A human-readable description for logging.
    var displayName: String { get }
}

/// Shared context passed to all reconciliation operations.
public struct ReconcileContext: Sendable {
    public let payloadStore: PayloadStore

    public init(payloadStore: PayloadStore) {
        self.payloadStore = payloadStore
    }
}
