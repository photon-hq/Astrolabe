/// The default telemetry implementation: every operation is a pass-through.
///
/// Astrolabe ships with this as the default `Astrolabe.telemetry` value, so
/// existing setups produce zero telemetry traffic without any opt-out step.
public struct NoopAstrolabeTelemetry: AstrolabeTelemetry {
    public init() {}

    public func withSpan<T: Sendable>(
        _ name: String,
        attributes: [String: TelemetryValue],
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await operation()
    }

    public func log(
        _ level: TelemetryLogLevel,
        _ message: String,
        attributes: [String: TelemetryValue]
    ) {}

    public func recordCounter(
        _ name: String,
        value: Int,
        attributes: [String: TelemetryValue]
    ) {}
}
