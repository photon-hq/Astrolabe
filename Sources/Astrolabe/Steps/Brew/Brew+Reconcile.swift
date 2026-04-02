/// Reconciliation metadata for a `Brew` leaf node.
public struct BrewInfo: ReconcilableNode {
    public let name: String
    public let type: Brew.PackageType

    public var displayName: String { "brew \(type == .cask ? "cask" : "formula") \(name)" }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        try await BrewHelper.uninstall(name, cask: type == .cask)
        context.payloadStore.remove(for: identity)
    }
}
