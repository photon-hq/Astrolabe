/// Something on the Mac that a declaration says should exist, and how it should look.
///
/// The value is the snapshot. `body` copies facts into stored properties; the static functions
/// see only that value and never read a fact — `@Fact` only works while a pass evaluates
/// `body`. Snapshots are written to `records.json`, so never store a secret — store a reference
/// and resolve it inside `rollout`.
///
/// Conform with `@Resource`, which also lets the engine find the type at launch:
///
/// ```swift
/// @Resource
/// struct StagingFile {
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
/// To repair the object when someone changes it behind the engine's back, add a `@Monitor`. It
/// reads a fact when `body` builds the resource; when the value changes, the engine reruns
/// `rollout` toward the same hash, and never cancels a rollout in flight for it.
///
/// `rollout` and `remove` are idempotent and check the Mac before they act: they re-run after
/// cancel, crash, or retry, and removing something that isn't there is a no-op. They cooperate
/// with cancellation — check `Task.isCancelled` between steps — because the engine cancels a
/// rollout as soon as the declaration moves on.
public protocol Resource: Codable, Sendable {
    /// Names this Swift type in `records.json`, e.g. `"staging.file"`. Must be unique across the
    /// app and must not change, or records written by older binaries can't be decoded.
    static var kind: String { get }

    /// Which object on the Mac this is. Derived from the stored properties.
    var id: String { get }

    /// How the object should look: a hash of the declared stored properties, usually via
    /// `Hash.of`. Leave `@Monitor`s out: the engine hashes them on their own.
    ///
    /// Never hash a fact the rollout itself changes, or a pass mid-rollout would see the
    /// rollout's own progress and cancel it. To react to such a fact, `@Monitor` it.
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

    /// Written by `@Resource`: conform with the macro, never by hand.
    static var __resourceRecord: __ResourceRecord { get }
}

/// Conforms the type to `Resource` and records it in the binary, so the engine finds every
/// resource type at launch. Like SwiftUI's views, nothing lists them.
///
/// The engine needs the type to decode a record in `records.json`. Without it, a resource that
/// `body` no longer declares would never be removed after a restart: its record could not be
/// read back.
///
/// ```swift
/// @Resource
/// struct StagingFile {
///     static let kind = "staging.file"
///     …
/// }
/// ```
///
/// The macro adds a `static let __resourceRecord` that the linker gathers into
/// `__DATA_CONST,__astrolabe_res`, and the conformance unless the type already declares it.
/// `Resource` requires the record, so a conformance without the macro doesn't compile: the
/// error says to add `@Resource`.
///
/// The type can't be generic or nested in a generic context: a record names one concrete type.
@attached(member, names: named(__resourceRecord))
@attached(extension, conformances: Resource)
public macro Resource() = #externalMacro(module: "AstrolabeMacros", type: "ResourceMacro")

extension Resource {
    public static var retryPolicy: RetryPolicy { .retry() }
    public static var timeout: Duration { .seconds(60 * 60) }

    /// Turns a conformance written without `@Resource` into an error that says so.
    @available(*, unavailable, message: "conform with `@Resource`, so the engine can find the type at launch")
    public static var __resourceRecord: __ResourceRecord { fatalError() }
}
