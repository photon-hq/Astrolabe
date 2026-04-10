import Foundation

/// Reconciliation metadata for a `Pkg` leaf node.
public struct PkgInfo: ReconcilableNode {
    public let providerDescription: String

    public var displayName: String { "pkg \(providerDescription)" }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preUninstall {
            for handler in handlers {
                do { try await handler.handler() }
                catch { print("[Astrolabe] preUninstall hook failed for \(identity.path): \(error)") }
            }
        }

        guard let record = context.payloadStore.record(for: identity) else { return }
        if case .pkg(let id, let files) = record {
            for file in files {
                try? FileManager.default.removeItem(atPath: file)
            }
            try await ProcessRunner.run("/usr/sbin/pkgutil", arguments: ["--forget", id])
        }
        context.payloadStore.remove(for: identity)

        if let handlers = context.callbacks?.postUninstall {
            for handler in handlers { await handler.handler() }
        }
    }
}
