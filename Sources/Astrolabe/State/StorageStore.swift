import AstrolabeUtils
import Foundation

/// Persistent string-keyed store for `@Storage` values.
///
/// Maps explicit string keys to JSON-encoded `Data`. Unlike `StateGraph` (position-keyed,
/// ephemeral), `StorageStore` is string-keyed and persisted to disk — values survive
/// daemon restart. Unlike `PayloadStore` (framework-only, Reconciler-written), `StorageStore`
/// is user-facing, written by consumer code via `@Storage` mutations.
///
/// Persisted at `/Library/Application Support/Astrolabe/storage.json`.
public final class StorageStore: @unchecked Sendable {
    public static let shared = StorageStore(fileURL: Persistence.storageURL)

    private let lock = NSLock()
    private let fileURL: URL
    private var entries: [String: Data] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Reads a value for the given key, decoding from stored JSON.
    /// Returns `defaultValue` if the key is absent or decoding fails.
    func get<V: Codable & Sendable>(_ key: String, default defaultValue: V) -> V {
        lock.withLock {
            guard let data = entries[key],
                  let value = try? JSONDecoder().decode(V.self, from: data)
            else { return defaultValue }
            return value
        }
    }

    /// Reads an optional value for the given key. Returns `nil` if the key is
    /// absent or decoding fails.
    func read<V: Codable & Sendable>(_ key: String) -> V? {
        lock.withLock {
            guard let data = entries[key],
                  let value = try? JSONDecoder().decode(V.self, from: data)
            else { return nil }
            return value
        }
    }

    /// Sets a value for the given key. Returns `true` if the value changed.
    /// Persists to disk synchronously on change (best-effort).
    func set<V: Codable & Equatable & Sendable>(_ key: String, value: V) -> Bool {
        lock.withLock {
            guard let newData = try? JSONEncoder().encode(value) else { return false }

            if let existing = entries[key],
               let oldValue = try? JSONDecoder().decode(V.self, from: existing),
               oldValue == value {
                return false
            }

            entries[key] = newData
            _persistLocked(key: key, data: newData)
            return true
        }
    }

    /// Snapshot of all `@Storage` entries for verbose telemetry.
    func telemetrySnapshot() -> String {
        lock.withLock {
            entries.keys.sorted().map { key in
                let data = entries[key]!
                let text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                return "\(key)=\(text)"
            }.joined(separator: "; ")
        }
    }

    /// Loads persisted entries from disk. Called on daemon startup before `onStart()`.
    public func load() {
        lock.withLock {
            guard let decoded = try? StorageFileCoordinator.loadEntries(from: fileURL) else { return }
            entries = decoded
        }
    }

    // MARK: - Private

    /// Persists only the changed key, merging with the latest on-disk snapshot.
    /// Called within the lock. Best-effort to preserve the previous API behavior.
    private func _persistLocked(key: String, data: Data) {
        guard let persisted = try? StorageFileCoordinator.mutateEntries(at: fileURL, { entries in
            entries[key] = data
            return true
        }) else { return }
        entries = persisted
    }
}
