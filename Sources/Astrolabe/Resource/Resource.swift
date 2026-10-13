/// Something on the Mac that a declaration says should exist, and how it should look.
///
/// The value is the snapshot. `body` copies state into stored properties; the static functions
/// see only that value, never a state object. `Codable` enforces this: an `@Observable` state
/// object isn't `Codable`, so it can't be stored here. Snapshots are written to `records.json`,
/// so never store a secret — store a reference and resolve it inside `rollout`.
///
/// ```swift
/// struct StagingFile: Resource {
///     static let kind = "staging.file"
///     let path: String
///     let contents: String
///     var id: String { "file:\(path)" }                        // which file
///
///     static func compute(_ f: StagingFile) -> String {
///         Hash.of("staging.file", f.path, f.contents)          // how it should look
///     }
///
///     @concurrent static func rollout(_ f: StagingFile) async throws { … }
///     @concurrent static func remove(_ f: StagingFile) async throws { … }
/// }
/// ```
///
/// Whatever decides *which* object on the Mac goes in `id`; whatever decides *how it should
/// look* goes in the hash. Changing an id-bearing property then becomes two independent
/// operations: roll out the new id, remove the old one.
///
/// `rollout` and `remove` are idempotent and check the Mac before they act: they re-run after
/// cancel, crash, or retry, and removing something that isn't there is a no-op. They cooperate
/// with cancellation — check `Task.isCancelled` between steps — because the engine cancels a
/// rollout as soon as the declaration moves on.
public protocol Resource: Codable, Sendable {
    /// Names this Swift type in `records.json`, e.g. `"staging.file"`. Must be unique across the
    /// app and must not change, or records written by older binaries can't be decoded.
    static var kind: String { get }

    /// Which object on the Mac this is. Derived from content, never from state.
    var id: String { get }

    /// How the object should look: a hash of the declared stored properties, usually via
    /// `Hash.of`. Never hash facts the rollout itself changes, or a pass mid-rollout would see
    /// the rollout's own progress and cancel it.
    static func compute(_ resource: Self) -> String

    /// Makes the Mac match this snapshot.
    @concurrent static func rollout(_ resource: Self) async throws

    /// Undoes it. Receives the snapshot that was last moved toward, which after a restart comes
    /// from `records.json`.
    @concurrent static func remove(_ resource: Self) async throws

    /// What the engine does when an operation fails. Default: `.retry()`.
    static var retryPolicy: RetryPolicy { get }

    /// The engine's backstop per operation. Past it the operation is cancelled and treated as a
    /// failure. Default: 60 minutes.
    static var timeout: Duration { get }
}

extension Resource {
    public static var retryPolicy: RetryPolicy { .retry() }
    public static var timeout: Duration { .seconds(60 * 60) }
}
