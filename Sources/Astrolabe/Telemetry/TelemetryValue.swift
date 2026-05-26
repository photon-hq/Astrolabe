/// A telemetry attribute value carried into spans, log events, and counters.
///
/// A small, low-fidelity envelope on purpose — the surface kept narrow makes it
/// hard for instrumentation call sites to accidentally pass arbitrary user
/// data (e.g. typed structs, error descriptions) into telemetry.
public enum TelemetryValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension TelemetryValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TelemetryValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension TelemetryValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension TelemetryValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Severity for `AstrolabeTelemetry.log(...)` events.
///
/// Mapped to OpenTelemetry severity numbers by the Signoz adapter.
public enum TelemetryLogLevel: Sendable, Equatable {
    case debug
    case info
    case warning
    case error
}
