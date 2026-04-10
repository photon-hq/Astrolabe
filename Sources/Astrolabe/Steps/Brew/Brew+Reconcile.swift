/// Reconciliation metadata for a `Brew` leaf node.
public struct BrewInfo: ReconcilableNode {
    public let name: String
    public let type: Brew.PackageType

    public var displayName: String { "brew \(type == .cask ? "cask" : "formula") \(name)" }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preUninstall {
            for handler in handlers {
                do { try await handler.handler() }
                catch { print("[Astrolabe] preUninstall hook failed for \(identity.path): \(error)") }
            }
        }

        try await BrewHelper.uninstall(name, cask: type == .cask)
        context.payloadStore.remove(for: identity)

        if let handlers = context.callbacks?.postUninstall {
            for handler in handlers { await handler.handler() }
        }
    }
}
