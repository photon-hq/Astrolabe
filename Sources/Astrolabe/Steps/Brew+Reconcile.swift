/// Metadata + reconciliation logic for a `Brew` leaf node.
public struct BrewInfo: ReconcilableNode {
    public let name: String
    public let type: BrewType

    public enum BrewType: String, Sendable {
        case formula
        case cask
    }

    public var displayName: String { "brew \(name)" }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        try await CatalogPackage(.homebrew).install()

        let user = BrewHelper.consoleUser()

        // Fast lock-free check via PATH lookup (formulas only — casks don't land in PATH)
        if type == .formula, ProcessRunner.commandExists(name) {
            print("[Astrolabe] \(name) already installed, skipping.")
            context.payloadStore.set(.formula(name: name), for: identity)
            return
        }

        // Install (or skip) under the brew semaphore so the `brew list` check
        // and `brew install` are atomic — no lock conflicts with parallel tasks.
        let record: PayloadRecord = type == .cask ? .cask(name: name) : .formula(name: name)
        try await BrewHelper.installIfNeeded(name, type: type, user: user)
        context.payloadStore.set(record, for: identity)
    }
}
