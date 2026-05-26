// MARK: - Privacy
//
// Astrolabe does not send telemetry by default. With `verbose: false` (default),
// only operational metadata is emitted. With `verbose: true`, internal setups may
// emit full errors, node names, environment, `@State`, `@Storage`, shell output,
// tokens, and declaration trees — see README.
//
// Contributor note: build attribute dicts only via TelemetryAttributes.* helpers.

/// An abstraction over a telemetry backend.
///
/// Default conformance is `NoopAstrolabeTelemetry`, which makes every method
/// a pass-through. The opt-in `SignozAstrolabeTelemetry` adapter is the only
/// type in Astrolabe that imports `SignozSwift`.
///
/// `withSpan` is async-only by design — Astrolabe's `tick()` is fully
/// synchronous and does not get a span.
public protocol AstrolabeTelemetry: Sendable {
    /// Wrap an async operation in a span. The span ends when the operation
    /// returns or throws. On throw, records error type only unless
    /// `verboseNodeAttributes` is true (then full `String(describing: error)`).
    func withSpan<T: Sendable>(
        _ name: String,
        attributes: [String: TelemetryValue],
        operation: @Sendable () async throws -> T
    ) async throws -> T

    /// Emit a structured log event.
    func log(
        _ level: TelemetryLogLevel,
        _ message: String,
        attributes: [String: TelemetryValue]
    )

    /// Increment a counter. The `Signoz` adapter is no-op for this method
    /// in the current PR; the surface exists so a future swift-metrics
    /// wiring can land without an API break.
    func recordCounter(
        _ name: String,
        value: Int,
        attributes: [String: TelemetryValue]
    )

    /// Flush pending telemetry. No-op for backends that do not buffer exports.
    func shutdown()

    /// When `true`, telemetry includes full debugging payloads (node identity,
    /// display names, error messages, environment, state, storage, shell output,
    /// config tree). Default is `false` (hash + error type only).
    var verboseNodeAttributes: Bool { get }
}

extension AstrolabeTelemetry {
    public var verboseNodeAttributes: Bool { false }

    public func shutdown() {}
    /// Convenience overload: omit attributes when none are needed.
    /// Has a strictly different signature from the protocol requirement
    /// (no `attributes:` parameter) to avoid accidental recursion.
    public func withSpan<T: Sendable>(
        _ name: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withSpan(name, attributes: [:], operation: operation)
    }

    public func log(_ level: TelemetryLogLevel, _ message: String) {
        log(level, message, attributes: [:])
    }

    public func recordCounter(_ name: String, value: Int = 1) {
        recordCounter(name, value: value, attributes: [:])
    }
}
