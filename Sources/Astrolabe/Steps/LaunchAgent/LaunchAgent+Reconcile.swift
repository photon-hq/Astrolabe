import Foundation

/// Reconciliation metadata for a `LaunchAgent` leaf node.
public struct LaunchAgentInfo: ReconcilableNode {
    public let label: String

    public var displayName: String { "launchAgent \(label)" }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preUninstall {
            for handler in handlers {
                do { try await handler.handler() }
                catch { print("[Astrolabe] preUninstall hook failed for \(identity.path): \(error)") }
            }
        }

        await LaunchctlHelper.deactivateAgentForAllUsers(label: label)
        try? FileManager.default.removeItem(atPath: "/Library/LaunchAgents/\(label).plist")
        context.payloadStore.remove(for: identity)

        if let handlers = context.callbacks?.postUninstall {
            for handler in handlers { await handler.handler() }
        }
    }
}
