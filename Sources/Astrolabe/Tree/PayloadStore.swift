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

    /// Reverses the system change this record represents.
    func performUnmount() async throws {
        switch self {
        case .formula(let name):
            try await BrewHelper.uninstall(name, cask: false)
        case .cask(let name):
            try await BrewHelper.uninstall(name, cask: true)
        case .pkg(let id, let files):
            for file in files {
                try? FileManager.default.removeItem(atPath: file)
            }
            try await ProcessRunner.run("/usr/sbin/pkgutil", arguments: ["--forget", id])
        case .catalog:
            break
        case .sys:
            break
        case .launchDaemon(let label):
            await LaunchctlHelper.deactivateDaemon(label: label)
            try? FileManager.default.removeItem(atPath: "/Library/LaunchDaemons/\(label).plist")
        case .launchAgent(let label):
            await LaunchctlHelper.deactivateAgentForAllUsers(label: label)
            try? FileManager.default.removeItem(atPath: "/Library/LaunchAgents/\(label).plist")
        }
    }
}

/// A pure key-value store mapping declaration identity to runtime artifacts.
///
/// Thread-safe via locking. Any code can read/write — this is a database,
/// not reactive state. Changes here never trigger tree recalculation.
public final class PayloadStore: @unchecked Sendable {
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
