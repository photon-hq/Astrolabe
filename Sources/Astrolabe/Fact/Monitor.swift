import Foundation

/// Reads a fact into a resource, so the engine repairs the resource when the fact drifts. Like
/// `@Fact`, but for resources.
///
/// ```swift
/// @Resource
/// struct CommandLineToolsInstall {
///     static let kind = "astrolabe.commandLineTools"
///     let minimum: CLTVersion?
///     @Monitor(\.commandLineTools.isInstalled) var isInstalled   // a deletion reruns rollout
///     …
/// }
/// ```
///
/// The fact is read once, when `body` builds the resource, and the value is stored in the
/// snapshot. The engine hashes every monitor into a *monitor hash*, apart from `compute`'s.
/// When only the monitor hash changes, the engine reruns `rollout` toward the same declared
/// hash: someone deleted CLT, so it is installed again.
///
/// - Read from `Facts` only. A custom read is an `@FactEntry`; a derived value is a computed
///   property on a namespace, like `isInstalled`.
/// - Monitor the coarsest value that still notices the breakage: every change reruns `rollout`.
///   CLT monitors `isInstalled`, not `installed`, so an update made outside Astrolabe starts
///   nothing.
/// - The fact needs an `.every(…)` schedule, or a drift is never seen.
/// - Detection is edge-triggered: a rollout that returns counts as the fix, and nothing reruns
///   until the value changes again. `rollout` must check its work and throw if the fix didn't
///   take, so the retry policy applies.
///
/// Unlike `@Fact`, it reads once, at construction, and feeds the monitor hash rather than
/// `compute`. So a change never cancels a running rollout: the engine lets it end, then reruns
/// if the value still differs. A monitor may watch a fact the rollout itself changes; a hashed
/// fact may not.
///
/// The value is `nil` when the resource was built outside a pass, such as in a test, or decoded
/// from a record written before the monitor existed. `rollout` and `remove` must handle that.
@propertyWrapper
public struct Monitor<Value: Codable & Sendable & HashPart>: Codable, Sendable, HashPart {
    /// What the fact read when `body` built the resource, or `nil` when it was built outside a
    /// pass. For an optional `Value`, a read `nil` is `.some(nil)`.
    let value: Value?

    public init(_ keyPath: KeyPath<Facts, Value>) {
        // Swift runs this again ahead of a synthesized `init(from:)`, so decoding a record must
        // never read or assert: only a pass reads.
        guard Thread.isMainThread, let store = MainActor.assumeIsolated({ FactStore.current }) else {
            value = nil
            return
        }
        value = Facts(store: store)[keyPath: keyPath]
    }

    /// A monitor that read `value`, or wasn't read with `nil`. For tests.
    init(observed value: Value?) {
        self.value = value
    }

    /// What the fact read when `body` built the resource, or `nil` when it wasn't read.
    public var wrappedValue: Value? { value }

    // A stored property is coded through the keyed-container overloads below. These are for
    // any other context.

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }

    public func encode(into encoder: inout HashEncoder) {
        value.encode(into: &encoder)
    }
}

extension Monitor: Equatable where Value: Equatable {}
extension Monitor: Hashable where Value: Hashable {}

extension KeyedEncodingContainer {
    /// Leaves an unread monitor out of the snapshot, so it stays apart from a read `nil`.
    public mutating func encode<Value>(_ monitor: Monitor<Value>, forKey key: Key) throws {
        guard let value = monitor.value else { return }
        try encode(value, forKey: key)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a missing key as unread, so a record written before the monitor existed decodes.
    public func decode<Value>(_: Monitor<Value>.Type, forKey key: Key) throws -> Monitor<Value> {
        guard contains(key) else { return Monitor(observed: nil) }
        return Monitor(observed: try decode(Value.self, forKey: key))
    }
}

/// A `Monitor` of any value, for the walk in `AnyResource.monitors`.
protocol _AnyMonitor: HashPart {
    /// The fact was read: the resource was built while a pass evaluated `body`.
    var isObserved: Bool { get }
}

extension Monitor: _AnyMonitor {
    var isObserved: Bool { value != nil }
}
