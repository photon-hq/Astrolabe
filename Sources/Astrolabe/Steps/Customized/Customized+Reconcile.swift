/// Reconciliation logic for a `Customized` leaf node.
///
/// Holds the user's three closures. A node revived from a `PayloadRecord` after a daemon
/// restart has `nil` closures — it knows its identity but can't re-run custom logic, so it
/// degrades gracefully (mirrors a persisted `.custom` `Sys` setting).
public struct CustomizedNode: ReconcilableNode {
    public let id: String

    let mountAction: (@Sendable () async throws -> Void)?
    let checkAction: (@Sendable () async throws -> Bool)?
    let unmountAction: (@Sendable () async throws -> Void)?

    public var displayName: String { "customized \(id)" }

    /// Live form built from a `Customized` declaration.
    init(
        id: String,
        mount: @escaping @Sendable () async throws -> Void,
        check: @escaping @Sendable () async throws -> Bool,
        unmount: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.mountAction = mount
        self.checkAction = check
        self.unmountAction = unmount
    }

    /// Persisted form revived from a `PayloadRecord`. The closures are gone, so this can
    /// only clear its payload — not re-run custom mount/check/unmount.
    public init(id: String) {
        self.id = id
        self.mountAction = nil
        self.checkAction = nil
        self.unmountAction = nil
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        guard let checkAction, let mountAction else {
            print("[Astrolabe] Cannot reconcile customized step \(id) from persisted tree.")
            return
        }

        if let handlers = context.callbacks?.preInstall {
            for handler in handlers { try await handler.handler() }
        }

        // Converge: only do the work when the desired state isn't already present.
        if try await checkAction() {
            print("[Astrolabe] \(displayName) already satisfied, skipping.")
        } else {
            print("[Astrolabe] Applying \(displayName)...")
            try await mountAction()
            print("[Astrolabe] Applied \(displayName).")
        }

        if let handlers = context.callbacks?.postInstall {
            for handler in handlers { await handler.handler() }
        }

        context.payloadStore.set(.customized(id: id), for: identity)
    }

    public func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        // A persisted form can't verify itself — assume healthy.
        guard let checkAction else { return .healthy }
        return try await checkAction() ? .healthy : .drifted(reason: "\(displayName) drifted")
    }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preUninstall {
            for handler in handlers {
                do { try await handler.handler() }
                catch { print("[Astrolabe] preUninstall hook failed for \(identity.path): \(error)") }
            }
        }

        if let unmountAction {
            try await unmountAction()
        } else {
            print("[Astrolabe] Cannot run custom unmount for \(id) from persisted tree.")
        }
        context.payloadStore.remove(for: identity)

        if let handlers = context.callbacks?.postUninstall {
            for handler in handlers { await handler.handler() }
        }
    }
}
