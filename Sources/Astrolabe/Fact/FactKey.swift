/// A fact about the Mac: how to read it, how often, and what `body` sees before the first read.
///
/// Mirrors SwiftUI's `EnvironmentKey`. The key type is the fact's identity; an extension on
/// `Facts` gives it a key path, and components read it with `@Fact(\.x)`. `@FactEntry` writes
/// both from one declaration and is the usual way to declare a fact; write the key by hand when
/// code needs to name it, keys share a `read()`, or the key keeps state of its own.
///
/// ```swift
/// struct StagingFiles: FactKey {
///     static let defaultValue: [String: String] = [:]           // never acted on
///     static let schedule: FactSchedule = .every(.seconds(1))
///     @concurrent static func read() async throws -> [String: String] {
///         try StateFile.read(StateFile.path)                     // a throw means "couldn't read", never "nothing"
///     }
/// }
///
/// extension Facts {
///     var stagingFiles: [String: String] { self[StagingFiles.self] }
/// }
/// ```
///
/// Unlike SwiftUI's, the default is never a guess about the Mac. It only lets `body` evaluate
/// before the first read lands: a pass that reads a fact still at its default acts on nothing,
/// and the fact's first value wakes the next pass.
public protocol FactKey: SendableMetatype {
    associatedtype Value: Equatable & Sendable

    /// What `body` sees until the first read lands. The engine never acts on it. Default for an
    /// optional `Value`: `nil`.
    static var defaultValue: Value { get }

    /// When to read again after a read returns. Default: `.once`.
    static var schedule: FactSchedule { get }

    /// How long one read may take. Past it the read is cancelled, abandoned, and counts as a
    /// failure. Default: 30 seconds.
    static var timeout: Duration { get }

    /// Reads the fact from the Mac, off the main actor.
    ///
    /// Throw when the fact couldn't be read: the engine keeps the last value, or before the
    /// first one keeps every pass that reads it waiting, and retries with backoff. Never return
    /// an empty value for "couldn't read": the engine removes whatever isn't declared. To let a
    /// fact that can't be read stop holding passes back, make the read infallible — return
    /// `nil` from `try?` — so `nil` is a real reading.
    @concurrent static func read() async throws -> Value
}

extension FactKey {
    public static var schedule: FactSchedule { .once }
    public static var timeout: Duration { .seconds(30) }
}

extension FactKey where Value: ExpressibleByNilLiteral {
    public static var defaultValue: Value { nil }
}

extension FactKey {
    /// The name in logs, telemetry and the dry run: the type name, or the property name of an
    /// `@FactEntry` key (`__Key_stagingFiles` → `stagingFiles`).
    static var factName: String {
        let type = String(describing: Self.self)
        return type.hasPrefix("__Key_") ? String(type.dropFirst(6)) : type
    }
}

/// When a fact is read again after a read returns.
///
/// A fact is first read when a pass first reads it, and keeps being read until shutdown. A read
/// that throws or times out is retried with backoff (15 seconds, doubling to 30 minutes).
public struct FactSchedule: Sendable, Equatable {
    /// The time between reads, or `nil` to read until one succeeds.
    let interval: Duration?

    /// Read until one read succeeds, then never again.
    public static let once = FactSchedule(interval: nil)

    /// Read every `interval`. After a failure, retry after the backoff or `interval`, whichever
    /// is sooner.
    public static func every(_ interval: Duration) -> FactSchedule {
        FactSchedule(interval: interval)
    }
}
