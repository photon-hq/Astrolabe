import AstrolabeUtils
import Foundation

/// Where Astrolabe keeps its files: `/Library/Application Support/Astrolabe/`.
public enum Persistence {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/Astrolabe")
    /// The engine's records: the last successful snapshot per id. See `RecordStore`.
    public static let recordsURL = directory.appendingPathComponent("records.json")
    public static let storageURL = StorageClient.fileURL
}
