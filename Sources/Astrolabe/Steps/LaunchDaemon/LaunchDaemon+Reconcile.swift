import Foundation

/// Reconciliation metadata for a `LaunchDaemon` leaf node.
public struct LaunchDaemonInfo: ReconcilableNode {
    public let label: String

    public var displayName: String { "launchDaemon \(label)" }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        await LaunchctlHelper.deactivateDaemon(label: label)
        try? FileManager.default.removeItem(atPath: "/Library/LaunchDaemons/\(label).plist")
        context.payloadStore.remove(for: identity)
    }
}
