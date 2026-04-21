import Foundation

/// Read-only accessors over Astrolabe's persisted state, safe to call from
/// consumer commands. Loads from disk on demand — no engine required.
public enum AstrolabeState {
    /// Reads a `@Storage`-persisted value by its string key.
    public static func storage<T: Codable & Sendable>(_ key: String, as _: T.Type) -> T? {
        StorageStore.shared.load()
        return StorageStore.shared.read(key)
    }

    /// Loads payload records from disk. Returns a snapshot — the live daemon
    /// (if any) may write more between the load and the caller reading.
    public static func payloads() -> [(NodeIdentity, PayloadRecord)] {
        let store = PayloadStore()
        try? store.load(from: Persistence.payloadURL)
        return store.allIdentities().compactMap { id in
            store.record(for: id).map { (id, $0) }
        }
    }

    /// Loads the set of leaf identities persisted by the engine's last tick.
    public static func identities() -> Set<NodeIdentity> {
        Persistence.loadIdentities()
    }
}
