import Foundation

/// A runtime artifact recorded during reconciliation.
///
/// Payloads capture what the system reported after installation — the information
/// needed to cleanly uninstall. Separate from the tree because payloads come from
/// the system, not from code.
public enum PayloadRecord: Codable, Sendable {
    /// A Homebrew formula.
    case formula(name: String)
    /// A Homebrew cask.
    case cask(name: String)
    /// A macOS .pkg with its receipt ID and installed files.
    case pkg(id: String, files: [String])
    /// A catalog item.
    case catalog(item: String)
    /// A system configuration (mount-only, no unmount).
    case sys(setting: String)
    /// A macOS LaunchDaemon in `/Library/LaunchDaemons/`.
    case launchDaemon(label: String)
    /// A macOS LaunchAgent in `/Library/LaunchAgents/`.
    case launchAgent(label: String)

    /// Reconstructs the `ReconcilableNode` that knows how to unmount this record.
    func reconcilableNode() -> any ReconcilableNode {
        switch self {
        case .formula(let name): BrewInfo(name: name, type: .formula)
        case .cask(let name): BrewInfo(name: name, type: .cask)
        case .pkg(let id, _): PkgInfo(providerDescription: id)
        case .catalog: PkgInfo(providerDescription: "catalog")
        case .sys: SysInfo(source: .custom(typeName: "persisted"))
        case .launchDaemon(let label): LaunchDaemonInfo(label: label)
        case .launchAgent(let label): LaunchAgentInfo(label: label)
        }
    }
}

/// A pure key-value store mapping declaration identity to runtime artifacts.
///
/// Thread-safe via locking. Any code can read/write — this is a database,
/// not reactive state. Changes here never trigger tree recalculation.
public final class PayloadStore: @unchecked Sendable {
    public static let shared = PayloadStore()

    private let lock = NSLock()
    private var entries: [NodeIdentity: PayloadRecord] = [:]

    public init() {}

    public func record(for identity: NodeIdentity) -> PayloadRecord? {
        lock.withLock { entries[identity] }
    }

    public func set(_ record: PayloadRecord, for identity: NodeIdentity) {
        lock.withLock { entries[identity] = record }
    }

    @discardableResult
    public func remove(for identity: NodeIdentity) -> PayloadRecord? {
        lock.withLock { entries.removeValue(forKey: identity) }
    }

    /// Returns all identities that have payload records.
    public func allIdentities() -> Set<NodeIdentity> {
        lock.withLock { Set(entries.keys) }
    }

    // MARK: - Persistence

    public func save(to url: URL) throws {
        let data = lock.withLock { try? JSONEncoder().encode(entries) }
        guard let data else { return }
        try data.write(to: url)
    }

    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([NodeIdentity: PayloadRecord].self, from: data)
        lock.withLock { entries = decoded }
    }
}
