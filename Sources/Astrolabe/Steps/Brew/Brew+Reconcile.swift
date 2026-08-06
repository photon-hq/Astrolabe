/// Reconciliation metadata for a `Brew` leaf node.
public struct BrewInfo: ReconcilableNode {
    public let name: String
    public let type: Brew.PackageType

    public var displayName: String { "brew \(type == .cask ? "cask" : "formula") \(name)" }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preInstall {
            for handler in handlers { try await handler.handler() }
        }

        // Self-heal Homebrew before installing — preserves the prior bootstrap
        // behavior where `brew` would be installed on demand.
        try await CatalogPackage(.homebrew).install()
        try await BrewHelper.installIfNeeded(name, type: type, user: BrewHelper.brewUser())

        if let handlers = context.callbacks?.postInstall {
            for handler in handlers { await handler.handler() }
        }

        let record: PayloadRecord = type == .cask ? .cask(name: name) : .formula(name: name)
        context.payloadStore.set(record, for: identity)
    }

    public func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        // One Cellar/Caskroom read, no subprocess. This replaced a `$PATH` fast path that
        // short-circuited formulas, and it supersedes that probe on accuracy rather than
        // merely on cost: `$PATH` answers "some binary by this name exists", so a `node` from
        // nvm or asdf reported healthy while the brew formula was gone. It also has an answer
        // for casks, which install an `.app` and never had a fast path at all.
        guard BrewHelper.isInstalled(name, type: type) else {
            return .drifted(reason: "brew \(name) not installed")
        }
        return .healthy
    }

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
