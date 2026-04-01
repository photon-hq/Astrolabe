import Foundation

/// Manages persistence of the payload store to disk.
///
/// Stored at `/Library/Application Support/Astrolabe/`.
/// The tree is ephemeral (rebuilt from code each tick) — only PayloadStore persists.
public struct Persistence: Sendable {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/Astrolabe")
    public static let payloadURL = directory.appendingPathComponent("payloads.json")

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
}
