// MARK: - Privacy
//
// Astrolabe does not send telemetry by default. Telemetry can be enabled
// explicitly with SignozAstrolabeTelemetry. Astrolabe telemetry records
// operational metadata only. Astrolabe telemetry must not record secrets,
// file contents, full config contents, or raw command output.
//
// Contributor note: when adding instrumentation, build attribute dicts
// only via TelemetryAttributes.* helpers. Never embed `displayName`,
// `identity.path`, `\(error)`, or arbitrary user-supplied strings.

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
    /// returns or throws. On throw, implementations must record only the
    /// error type name (never `\(error)`) and re-throw the original error
    /// unchanged.
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
}

extension AstrolabeTelemetry {
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
