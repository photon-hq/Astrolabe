import Foundation

/// Reconciliation metadata for a `LaunchAgent` leaf node.
public struct LaunchAgentInfo: ReconcilableNode {
    public let label: String

    public var displayName: String { "launchAgent \(label)" }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        await LaunchctlHelper.deactivateAgentForAllUsers(label: label)
        try? FileManager.default.removeItem(atPath: "/Library/LaunchAgents/\(label).plist")
        context.payloadStore.remove(for: identity)
    }
}
