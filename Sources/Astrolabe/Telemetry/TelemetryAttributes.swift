import CryptoKit
import Foundation

/// Centralized constructors for telemetry attribute dicts.
///
/// All instrumentation call sites in Astrolabe core build attributes through
/// these helpers. Direct `[String: TelemetryValue]` literals at call sites
/// are forbidden by review convention — this file is the single place where
/// the privacy policy is enforced.
///
/// When `verbose` is false, only operational metadata (kinds, hashes, counts) is emitted.
/// When `verbose` is true (opt-in), resource ids, full errors, and shell output may be included.
enum TelemetryAttributes {

    private static let maxAttributeStringLength = 4096

    /// `astrolabe.engine.started` attributes. Operational metadata only.
    @MainActor
    static func runAttributes<App: Astrolabe>(
        _ appType: App.Type,
        mode: EngineMode,
        records: Int
    ) -> [String: TelemetryValue] {
        [
            "astrolabe.engine.mode": .string(mode.rawValue),
            "astrolabe.records.count": .int(records),
            "telemetry.backend": .string(String(describing: type(of: App.telemetry))),
        ]
    }

    /// `astrolabe.pass` attributes. A pass that read a fact before its first value declares
    /// nothing and only enforces operation deadlines; `facts_waiting` counts those facts.
    static func passAttributes(
        declared: Int,
        actions: Int,
        holds: Int,
        factsRead: Int,
        factsWaiting: Int
    ) -> [String: TelemetryValue] {
        [
            "astrolabe.pass.declared": .int(declared),
            "astrolabe.pass.actions": .int(actions),
            "astrolabe.pass.holds": .int(holds),
            "astrolabe.pass.facts_read": .int(factsRead),
            "astrolabe.pass.facts_waiting": .int(factsWaiting),
        ]
    }

    /// `astrolabe.facts.waiting` fields: the facts a pass read before their first value. Fact
    /// names are Swift type names, so they are logged even when not verbose.
    static func factsWaitingAttributes(_ facts: [String]) -> [String: TelemetryValue] {
        [
            "astrolabe.facts.waiting": .string(truncate(facts.joined(separator: ", "))),
            "astrolabe.facts.waiting_count": .int(facts.count),
        ]
    }

    /// `astrolabe.fact.read_failed` fields: which fact, whether it has a last value to keep, and
    /// the error.
    static func factReadFailedAttributes(
        fact: String,
        hasValue: Bool,
        error: any Error,
        verbose: Bool
    ) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [
            "astrolabe.fact.name": .string(fact),
            "astrolabe.fact.has_value": .bool(hasValue),
        ]
        attrs.merge(errorAttributes(error, verbose: verbose)) { _, new in new }
        return attrs
    }

    /// Per-resource attributes: its kind plus a stable hash of its id.
    /// When `verbose` is true, also the id itself, which may name paths or packages.
    static func resourceAttributes(id: String, kind: String, verbose: Bool) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [
            "astrolabe.resource.kind": .string(kind),
            "astrolabe.resource.id_hash": .string(idHash(id)),
        ]
        if verbose {
            attrs["astrolabe.resource.id"] = .string(truncate(id))
        }
        return attrs
    }

    /// Operation events: the resource, which operation (`rollout`, `remove`, `rollback`), and
    /// for rollouts and removals, which attempt toward the target this is.
    static func operationAttributes(
        id: String,
        kind: String,
        operation: String,
        attempt: Int?,
        verbose: Bool
    ) -> [String: TelemetryValue] {
        var attrs = resourceAttributes(id: id, kind: kind, verbose: verbose)
        attrs["astrolabe.operation.kind"] = .string(operation)
        if let attempt {
            attrs["astrolabe.operation.attempt"] = .int(attempt)
        }
        return attrs
    }

    static func cancelAttributes(_ reason: CancelReason) -> [String: TelemetryValue] {
        ["astrolabe.operation.cancel_reason": .string(reason.rawValue)]
    }

    /// `astrolabe.operation.failed` fields: the policy that applies and failures in a row.
    static func failureAttributes(policy: RetryPolicy, attempts: Int) -> [String: TelemetryValue] {
        let name = switch policy {
        case .retry: "retry"
        case .rollback: "rollback"
        case .wait: "wait"
        }
        return [
            "astrolabe.operation.retry_policy": .string(name),
            "astrolabe.operation.attempts": .int(attempts),
        ]
    }

    /// `astrolabe.declaration.duplicate_id` fields.
    static func duplicateAttributes(id: String, count: Int, verbose: Bool) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [
            "astrolabe.resource.id_hash": .string(idHash(id)),
            "astrolabe.declaration.duplicate_count": .int(count),
        ]
        if verbose {
            attrs["astrolabe.resource.id"] = .string(truncate(id))
        }
        return attrs
    }

    /// `astrolabe.records.reset` fields.
    static func recordsResetAttributes(reason: String, movedAside: Bool) -> [String: TelemetryValue] {
        [
            "astrolabe.records.reset_reason": .string(reason),
            "astrolabe.records.moved_aside": .bool(movedAside),
        ]
    }

    static func shutdownAttributes(abandoned: Int) -> [String: TelemetryValue] {
        ["astrolabe.engine.abandoned_operations": .int(abandoned)]
    }

    /// Error fields for logs and spans. Verbose adds full message and shell details.
    static func errorAttributes(_ error: any Error, verbose: Bool) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [
            "astrolabe.error.type": .string(errorTypeName(error)),
        ]
        guard verbose else { return attrs }
        attrs["astrolabe.error.message"] = .string(truncate(String(describing: error)))
        if case ReconcileError.processFailed(let path, let arguments, let output) = error {
            attrs["astrolabe.shell.path"] = .string(truncate(path))
            attrs["astrolabe.shell.arguments"] = .string(truncate(arguments.joined(separator: " ")))
            attrs["astrolabe.shell.output"] = .string(truncate(output))
        }
        return attrs
    }

    /// Span status description passed to OpenTelemetry backends.
    static func errorStatusDescription(_ error: any Error, verbose: Bool) -> String {
        verbose ? truncate(String(describing: error)) : errorTypeName(error)
    }

    /// Render an error as just its type name. Strips associated values, full
    /// descriptions, paths, and any other content that could leak.
    static func errorTypeName(_ error: any Error) -> String {
        String(describing: type(of: error))
    }

    /// First 8 hex chars of SHA-256 over a resource id.
    static func idHash(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func truncate(_ value: String) -> String {
        guard value.count > maxAttributeStringLength else { return value }
        return String(value.prefix(maxAttributeStringLength)) + "…(\(value.count) chars)"
    }
}
