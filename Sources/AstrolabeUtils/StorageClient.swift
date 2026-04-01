import Foundation

/// Lightweight client for reading and writing Astrolabe's persistent storage
/// from any process on the Mac.
///
/// The Astrolabe daemon persists `@Storage` values to a shared JSON file at
/// `/Library/Application Support/Astrolabe/storage.json`. This client provides
/// access to that file without depending on the full Astrolabe framework.
///
/// ```swift
/// import AstrolabeUtils
///
/// let client = StorageClient()
/// let browser: String? = client.read("preferredBrowser")
/// ```
///
/// **Note:** The Astrolabe daemon does not watch the file for external changes.
/// If you write a value from another process, the daemon will not react until
/// its next restart or until a `@Storage` property with the same key is read.
public struct StorageClient: Sendable {
    /// The shared storage file location.
    public static let fileURL = URL(fileURLWithPath: "/Library/Application Support/Astrolabe/storage.json")

    public init() {}

    // MARK: - Read

    /// Reads a single value by key. Returns `nil` if the key is absent or decoding fails.
    public func read<V: Decodable>(_ key: String, as type: V.Type = V.self) -> V? {
        guard let entries = loadEntries(),
              let data = entries[key]
        else { return nil }
        return try? JSONDecoder().decode(V.self, from: data)
    }

    /// Returns all keys currently in storage.
    public func keys() -> [String] {
        guard let entries = loadEntries() else { return [] }
        return Array(entries.keys)
    }

    // MARK: - Write

    /// Writes a value for the given key. Creates the file and directory if needed.
    public func write<V: Encodable>(_ key: String, value: V) throws {
        var entries = loadEntries() ?? [:]
        entries[key] = try JSONEncoder().encode(value)
        let dir = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: Self.fileURL)
    }

    /// Removes a key from storage. No-op if the key doesn't exist.
    public func remove(_ key: String) throws {
        guard var entries = loadEntries() else { return }
        guard entries.removeValue(forKey: key) != nil else { return }
        let data = try JSONEncoder().encode(entries)
        try data.write(to: Self.fileURL)
    }

    // MARK: - Private

    private func loadEntries() -> [String: Data]? {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
        return try? JSONDecoder().decode([String: Data].self, from: data)
    }
}
