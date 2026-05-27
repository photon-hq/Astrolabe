/// A leaf node that knows how to reconcile itself onto the system.
///
/// Each reconcilable type carries its own mount/loop/unmount logic, following
/// SwiftUI's pattern where each primitive owns its lifecycle. The Reconciler
/// delegates to this protocol instead of switching on a central enum.
public protocol ReconcilableNode: Sendable {
    /// Perform the system changes for this node (install, configure, etc.).
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws

    /// Verify the node's declared state still matches reality. Called periodically
    /// while the node is mounted. Returning `.drifted` triggers a re-mount through
    /// the same `mount` pipeline as the initial attempt — `loop` is the framework's
    /// only convergence signal. Throwing is treated as `.drifted` (bias toward
    /// re-convergence on transient errors).
    func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome

    /// Reverse the system changes for this node (uninstall, deactivate, etc.).
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws

    /// Cadence for `loop(_:)` while the node is mounted. Override per node type
    /// to change the default. Per-declaration overrides via a modifier may shadow this.
    var loopInterval: Duration { get }

    /// A human-readable description for logging.
    var displayName: String { get }
}

extension ReconcilableNode {
    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {}
    public func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome { .healthy }
    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {}
    public var loopInterval: Duration { .seconds(15) }
}

/// Result of a `ReconcilableNode.loop(_:)` call.
public enum LoopOutcome: Sendable, Equatable {
    /// State matches the declaration. No remediation needed.
    case healthy
    /// State has drifted from the declaration; engine should re-mount.
    case drifted(reason: String? = nil)
}

/// Shared context passed to all reconciliation operations.
public struct ReconcileContext: Sendable {
    public let payloadStore: PayloadStore
    public let callbacks: ModifierStore.Callbacks?

    public init(payloadStore: PayloadStore, callbacks: ModifierStore.Callbacks? = nil) {
        self.payloadStore = payloadStore
        self.callbacks = callbacks
    }
}
