import Darwin
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

    private let fileURL: URL

    public init(fileURL: URL = Self.fileURL) {
        self.fileURL = fileURL
    }

    // MARK: - Read

    /// Reads a single value by key. Returns `nil` if the key is absent or decoding fails.
    public func read<V: Decodable>(_ key: String, as type: V.Type = V.self) -> V? {
        guard let entries = try? StorageFileCoordinator.loadEntries(from: fileURL),
              let data = entries[key]
        else { return nil }
        return try? JSONDecoder().decode(V.self, from: data)
    }

    /// Returns all keys currently in storage.
    public func keys() -> [String] {
        guard let entries = try? StorageFileCoordinator.loadEntries(from: fileURL) else { return [] }
        return Array(entries.keys)
    }

    // MARK: - Write

    /// Writes a value for the given key. Creates the file and directory if needed.
    public func write<V: Encodable>(_ key: String, value: V) throws {
        let encoded = try JSONEncoder().encode(value)
        _ = try StorageFileCoordinator.mutateEntries(at: fileURL) { entries in
            entries[key] = encoded
            return true
        }
    }

    /// Removes a key from storage. No-op if the key doesn't exist.
    public func remove(_ key: String) throws {
        _ = try StorageFileCoordinator.mutateEntries(at: fileURL) { entries in
            entries.removeValue(forKey: key) != nil
        }
    }
}

package enum StorageFileCoordinator {
    package typealias Entries = [String: Data]

    private static let processLock = NSLock()

    package static func loadEntries(from fileURL: URL = StorageClient.fileURL) throws -> Entries {
        try withFileLock(for: fileURL, exclusive: false) {
            try loadEntriesUnlocked(from: fileURL)
        }
    }

    @discardableResult
    package static func mutateEntries(
        at fileURL: URL = StorageClient.fileURL,
        _ mutate: (inout Entries) throws -> Bool
    ) throws -> Entries {
        try withFileLock(for: fileURL, exclusive: true) {
            var entries = try loadEntriesUnlocked(from: fileURL)
            let shouldWrite = try mutate(&entries)
            if shouldWrite {
                try writeEntriesUnlocked(entries, to: fileURL)
            }
            return entries
        }
    }

    private static func loadEntriesUnlocked(from fileURL: URL) throws -> Entries {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode(Entries.self, from: data)
    }

    private static func writeEntriesUnlocked(_ entries: Entries, to fileURL: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func withFileLock<T>(
        for fileURL: URL,
        exclusive: Bool,
        _ body: () throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lockURL = fileURL.appendingPathExtension("lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o644))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }

        try acquireLock(fd, exclusive: exclusive)
        defer { releaseLock(fd) }

        return try body()
    }

    private static func acquireLock(_ fd: Int32, exclusive: Bool) throws {
        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(exclusive ? F_WRLCK : F_RDLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(fd, F_SETLKW, &lock) == -1 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func releaseLock(_ fd: Int32) {
        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = Darwin.fcntl(fd, F_SETLK, &lock)
    }
}
