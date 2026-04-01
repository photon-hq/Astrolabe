import Foundation

/// Manages persistence of the payload store and tree identities to disk.
///
/// Stored at `/Library/Application Support/Astrolabe/`.
public struct Persistence: Sendable {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/Astrolabe")
    public static let payloadURL = directory.appendingPathComponent("payloads.json")
    public static let identitiesURL = directory.appendingPathComponent("identities.json")

    public init() {}

    /// Ensures the storage directory exists.
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: Self.directory,
            withIntermediateDirectories: true
        )
    }

    /// Saves the payload store to disk.
    public func savePayloads(_ store: PayloadStore) throws {
        try store.save(to: Self.payloadURL)
    }

    /// Loads payloads into the store from disk.
    public func loadPayloads(into store: PayloadStore) {
        try? store.load(from: Self.payloadURL)
    }

    /// Saves the current tree's leaf identities to disk.
    public static func saveIdentities(_ identities: Set<NodeIdentity>) throws {
        let data = try JSONEncoder().encode(identities)
        try data.write(to: identitiesURL)
    }

    /// Loads persisted leaf identities from disk. Returns empty set on first boot.
    public static func loadIdentities() -> Set<NodeIdentity> {
        guard let data = try? Data(contentsOf: identitiesURL),
              let identities = try? JSONDecoder().decode(Set<NodeIdentity>.self, from: data)
        else { return [] }
        return identities
    }
}
