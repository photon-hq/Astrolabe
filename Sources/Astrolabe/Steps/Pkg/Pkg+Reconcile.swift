import Foundation

/// Reconciliation metadata for a `Pkg` leaf node.
///
/// `install` / `isInstalledCheck` / `payloadRecord` are captured at `_buildTree`
/// time from the user's `PackageProvider` so they survive type erasure. The
/// persisted-form initializer leaves them as no-ops; the first tick after a
/// daemon restart replaces this with a fully-equipped instance via the
/// supervisor's `refresh(...)`.
public struct PkgInfo: ReconcilableNode {
    public let providerDescription: String
    let install: @Sendable () async throws -> Void
    let isInstalledCheck: @Sendable () async -> Bool
    let payloadRecord: PayloadRecord?

    public var displayName: String { "pkg \(providerDescription)" }

    /// Degraded initializer used when reconstructing from a `PayloadRecord` after
    /// daemon restart. `mount` becomes a no-op and `loop` reports `.healthy`
    /// until the first tick refreshes this with the build-time closures.
    public init(providerDescription: String) {
        self.providerDescription = providerDescription
        self.install = {}
        self.isInstalledCheck = { true }
        self.payloadRecord = nil
    }

    init(
        providerDescription: String,
        install: @escaping @Sendable () async throws -> Void,
        isInstalled: @escaping @Sendable () async -> Bool,
        payloadRecord: PayloadRecord?
    ) {
        self.providerDescription = providerDescription
        self.install = install
        self.isInstalledCheck = isInstalled
        self.payloadRecord = payloadRecord
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preInstall {
            for handler in handlers { try await handler.handler() }
        }

        try await install()

        if let handlers = context.callbacks?.postInstall {
            for handler in handlers { await handler.handler() }
        }

        if let record = payloadRecord {
            context.payloadStore.set(record, for: identity)
        }
    }

    public func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        await isInstalledCheck() ? .healthy : .drifted(reason: "\(providerDescription) not installed")
    }

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
