import Foundation

/// Manages persistence of the tree and payload store to disk.
///
/// Both are stored at `/Library/Application Support/Astrolabe/`.
public struct Persistence: Sendable {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/Astrolabe")
    public static let treeURL = directory.appendingPathComponent("tree.json")
    public static let payloadURL = directory.appendingPathComponent("payloads.json")

    public init() {}

    /// Ensures the storage directory exists.
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: Self.directory,
            withIntermediateDirectories: true
        )
    }

    /// Saves the tree to disk.
    public func saveTree(_ tree: TreeNode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(tree)
        try data.write(to: Self.treeURL)
    }

    /// Loads the previous tree from disk, or `nil` if none exists.
    public func loadTree() -> TreeNode? {
        guard let data = try? Data(contentsOf: Self.treeURL) else { return nil }
        return try? JSONDecoder().decode(TreeNode.self, from: data)
    }

    /// Saves the payload store to disk.
    public func savePayloads(_ store: PayloadStore) async throws {
        try await store.save(to: Self.payloadURL)
    }

    /// Loads payloads into the store from disk.
    public func loadPayloads(into store: PayloadStore) async {
        try? await store.load(from: Self.payloadURL)
    }
}
