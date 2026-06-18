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

    public let verboseNodeAttributes: Bool

    /// SignozSwift's configuration type, re-exported so callers can tune the
    /// full pipeline — endpoint, headers, transport security, host name,
    /// resource attributes, local persistence, auto-instrumentation toggles —
    /// without importing SignozSwift themselves.
    public typealias Configuration = SignozSwift.Configuration

    /// Configure and start the Signoz pipeline.
    ///
    /// - Parameters:
    ///   - serviceName: Service name used for resource identification.
    ///   - verbose: When `true`, emits full debugging attributes (errors,
    ///     secrets, env, state, config tree).
    ///   - configure: Mutates the `Configuration` before the pipeline starts.
    ///     Astrolabe applies its own defaults first (TLS transport, per-span
    ///     flush); this closure runs after and can override anything.
    public init(
        serviceName: String = "astrolabe",
        verbose: Bool = false,
        configure: ((inout Configuration) -> Void)? = nil
    ) {
        self.verboseNodeAttributes = verbose
        Signoz.start(serviceName: serviceName) { config in
            // Astrolabe's defaults differ from SignozSwift's: TLS transport
            // (not plaintext) and per-span flush (not batched). Applied before
            // the caller's closure so callers can still override them.
            config.transportSecurity = .tls
            config.spanProcessing = .simple
            configure?(&config)
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
                span.status = .error(
                    description: TelemetryAttributes.errorStatusDescription(
                        error,
                        verbose: verboseNodeAttributes
                    )
                )
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
