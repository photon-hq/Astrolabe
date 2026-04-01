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

        // Check if already installed
        let alreadyInstalled: Bool = switch type {
        case .formula: ProcessRunner.commandExists(name) || BrewHelper.isInstalled(name, flag: "--formula", user: user)
        case .cask: BrewHelper.isInstalled(name, flag: "--cask", user: user)
        }
        if alreadyInstalled {
            print("[Astrolabe] \(name) already installed, skipping.")
            let record: PayloadRecord = type == .cask
                ? .cask(name: name) : .formula(name: name)
            context.payloadStore.set(record, for: identity)
            return
        }

        let userDesc = user.map { "as \($0)" } ?? "as root"
        switch type {
        case .formula:
            print("[Astrolabe] Installing formula \(name) \(userDesc)...")
            try await BrewHelper.run(["install", name], user: user)
            context.payloadStore.set(.formula(name: name), for: identity)
        case .cask:
            print("[Astrolabe] Installing cask \(name) \(userDesc)...")
            try await BrewHelper.run(["install", "--cask", name], user: user)
            context.payloadStore.set(.cask(name: name), for: identity)
        }
        print("[Astrolabe] Installed \(name).")
    }
}
