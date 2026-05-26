import SignozSwift

/// SignozSwift-backed telemetry implementation.
///
/// Configures and starts the SignozSwift OpenTelemetry pipeline in `init`.
/// Caller manages process-lifetime — call `shutdown()` before the process
/// exits to flush pending spans and logs.
///
/// This is the only file in Astrolabe that imports SignozSwift; all other
/// instrumentation talks to the `AstrolabeTelemetry` protocol.
public struct SignozAstrolabeTelemetry: AstrolabeTelemetry {

    /// Transport security mode for the OTLP/gRPC connection.
    /// Re-exported so callers don't need to import SignozSwift themselves.
    public enum TransportSecurity: Sendable {
        case plaintext
        case tls
    }

    public init(
        serviceName: String = "astrolabe",
        endpoint: String? = nil,
        environment: String? = nil,
        serviceVersion: String? = nil,
        headers: [String: String] = [:],
        transportSecurity: TransportSecurity = .plaintext
    ) {
        Signoz.start(serviceName: serviceName) { config in
            if let endpoint { config.endpoint = endpoint }
            if let environment { config.environment = environment }
            if let serviceVersion { config.serviceVersion = serviceVersion }
            config.headers = headers
            config.transportSecurity = (transportSecurity == .tls) ? .tls : .plaintext
            config.spanProcessing = .simple
        }
    }

    public func withSpan<T: Sendable>(
        _ name: String,
        attributes: [String: TelemetryValue],
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let otelAttrs = attributes.mapValues(Self.toAttributeValue)
        return try await Signoz.tracer.withSpan(name, attributes: otelAttrs) { (span: any Span) async throws -> T in
            do {
                return try await operation()
            } catch {
                span.status = .error(description: String(describing: type(of: error)))
                span.end()
                throw error
            }
        }
    }

    public func log(
        _ level: TelemetryLogLevel,
        _ message: String,
        attributes: [String: TelemetryValue]
    ) {
        let otelAttrs = attributes.mapValues(Self.toAttributeValue)
        switch level {
        case .debug: debug(message, attributes: otelAttrs)
        case .info: info(message, attributes: otelAttrs)
        case .warning: warn(message, attributes: otelAttrs)
        case .error: error(message, attributes: otelAttrs)
        }
    }

    public func recordCounter(
        _ name: String,
        value: Int,
        attributes: [String: TelemetryValue]
    ) {
        // Counters are no-op in this PR. The protocol method exists so a
        // follow-up can wire Counter via swift-metrics without an API break.
    }

    /// Flush pending telemetry and shut down. Call before process exit.
    /// Astrolabe does not call this automatically — the engine doesn't own
    /// the Signoz singleton; user code outside Astrolabe might also use it.
    public func shutdown() {
        Signoz.shutdown()
    }

    // MARK: - Conversion

    static func toAttributeValue(_ value: TelemetryValue) -> AttributeValue {
        switch value {
        case .string(let s): return .string(s)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .bool(let b): return .bool(b)
        }
    }
}
