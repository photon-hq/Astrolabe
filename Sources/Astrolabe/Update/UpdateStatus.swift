import Foundation

/// Read-only snapshot of the self-updater's recent activity. Persisted across
/// daemon restarts via `@Storage` (string-keyed JSON, separate from PayloadStore).
public struct UpdateStatus: Codable, Sendable {
    /// Wall-clock time of the most recent tick that successfully reached
    /// the source (regardless of whether an update was applied).
    public let lastCheckedAt: Date?

    /// SemVer string of the most recent release seen on the source.
    /// Updated even when the version equals or is older than the local one.
    public let lastSeenVersion: String?

    /// Wall-clock time of the most recent successful update (installer exited 0).
    public let lastUpdatedAt: Date?

    /// String description of the most recent error, or `nil` if the last tick
    /// completed without throwing.
    public let lastError: String?

    public init(
        lastCheckedAt: Date? = nil,
        lastSeenVersion: String? = nil,
        lastUpdatedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.lastCheckedAt = lastCheckedAt
        self.lastSeenVersion = lastSeenVersion
        self.lastUpdatedAt = lastUpdatedAt
        self.lastError = lastError
    }
}

/// Internal helper for the updater process to read/write `UpdateStatus` fields
/// in `StorageStore` without using `@Storage` (which requires being attached
/// to the tree state graph). Field-level setters; `nil` clears the key.
enum UpdateStatusStorage {
    static let prefix = "astrolabe.update."

    enum Key {
        static let lastCheckedAt   = prefix + "lastCheckedAt"
        static let lastSeenVersion = prefix + "lastSeenVersion"
        static let lastUpdatedAt   = prefix + "lastUpdatedAt"
        static let lastError       = prefix + "lastError"
    }

    /// Reads the current status from the (loaded) `StorageStore`.
    static func read() -> UpdateStatus {
        StorageStore.shared.load()
        return UpdateStatus(
            lastCheckedAt:   StorageStore.shared.read(Key.lastCheckedAt),
            lastSeenVersion: StorageStore.shared.read(Key.lastSeenVersion),
            lastUpdatedAt:   StorageStore.shared.read(Key.lastUpdatedAt),
            lastError:       StorageStore.shared.read(Key.lastError)
        )
    }

    static func setLastCheckedAt(_ value: Date?)     { _ = StorageStore.shared.set(Key.lastCheckedAt,   value: value) }
    static func setLastSeenVersion(_ value: String?) { _ = StorageStore.shared.set(Key.lastSeenVersion, value: value) }
    static func setLastUpdatedAt(_ value: Date?)     { _ = StorageStore.shared.set(Key.lastUpdatedAt,   value: value) }
    static func setLastError(_ value: String?)       { _ = StorageStore.shared.set(Key.lastError,       value: value) }
}

// MARK: - Public accessor

extension AstrolabeState {
    /// The most recent self-update activity recorded by the updater daemon.
    /// Returns a zero-filled struct if no updater has ever run.
    public static func updateStatus() -> UpdateStatus {
        UpdateStatusStorage.read()
    }
}
