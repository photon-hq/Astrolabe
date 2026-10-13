/// Declares a fact in one place: its key path, default, schedule, timeout, and read. Like
/// SwiftUI's `@Entry`.
///
/// ```swift
/// extension Facts {
///     /// Which files should exist under `StateFile.directory`, and what they contain.
///     @FactEntry(schedule: .every(.seconds(1)), read: {
///         try StateFile.read(StateFile.path)                 // a throw means "couldn't read", never "nothing"
///     })
///     var stagingFiles: [String: String] = [:]               // never acted on
/// }
/// ```
///
/// The property's type is the fact's `Value` and its initializer is `defaultValue`. Leave the
/// initializer out only for an optional type: the default is then `nil`. `schedule` and
/// `timeout` default as `FactKey`'s do. `read` is a closure literal: its statements become the
/// key's `read()`, so name lookup inside it is a `read()`'s.
///
/// In a namespace, conform to `FactNamespace` and declare entries inside it:
///
/// ```swift
/// extension Facts {
///     var system: SystemFacts { SystemFacts(facts: self) }   // reads nothing by itself
/// }
///
/// struct SystemFacts: FactNamespace {
///     let facts: Facts
///
///     @FactEntry(read: { try await CSR.sipDisabled() })
///     var sipDisabled: Bool = false
///
///     @FactEntry(read: { try await NVRAM.amfiDisabled() })
///     var amfiDisabled: Bool = false
///
///     var readyForPackages: Bool { sipDisabled && amfiDisabled }  // tracked through both
/// }
/// ```
///
/// The expansion is the hand-written form: a getter, `self[__Key_stagingFiles.self]`, and a
/// `private struct __Key_stagingFiles: FactKey` beside it. Write a `FactKey` by hand instead
/// when code needs to name the key (a test that injects `Key.self`, a key another module
/// reuses), when keys share a `read()` through a protocol, or when the key keeps state of its
/// own. Both forms mix freely, even in one extension.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(__Key_))
public macro FactEntry<Value: Equatable & Sendable>(
    schedule: FactSchedule = .once,
    timeout: Duration = .seconds(30),
    read: @escaping @Sendable () async throws -> Value
) = #externalMacro(module: "AstrolabeMacros", type: "FactEntryMacro")
