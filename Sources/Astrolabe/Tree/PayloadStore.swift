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
}

/// Maps declaration identity to runtime artifacts.
///
/// Written during reconciliation (install), read during reconciliation (uninstall).
/// Persisted to disk alongside the tree.
public actor PayloadStore {
    private var entries: [NodeIdentity: PayloadRecord] = [:]

    public init() {}

    public func record(for identity: NodeIdentity) -> PayloadRecord? {
        entries[identity]
    }

    public func set(_ record: PayloadRecord, for identity: NodeIdentity) {
        entries[identity] = record
    }

    public func remove(for identity: NodeIdentity) {
        entries.removeValue(forKey: identity)
    }

    // MARK: - Persistence

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url)
    }

    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        entries = try JSONDecoder().decode([NodeIdentity: PayloadRecord].self, from: data)
    }
}
