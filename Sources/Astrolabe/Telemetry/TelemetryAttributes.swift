import CryptoKit
import Foundation

/// Centralized constructors for telemetry attribute dicts.
///
/// All instrumentation call sites in Astrolabe core build attributes through
/// these helpers. Direct `[String: TelemetryValue]` literals at call sites
/// are forbidden by review convention — this file is the single place where
/// the privacy policy is enforced.
///
/// When `verbose` is false, only operational metadata (types, hashes) is emitted.
/// When `verbose` is true (photon internal), full errors, node names, environment,
/// `@State`, `@Storage`, shell output, and tree snapshots may be included.
enum TelemetryAttributes {

    private static let maxAttributeStringLength = 4096

    /// Top-level run-span attributes. Pulls operational metadata only.
    static func runAttributes<App: Astrolabe>(_ appType: App.Type, verbose: Bool = false) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [
            "astrolabe.daemon_mode": .bool(App.daemonMode),
            "telemetry.backend": .string(String(describing: type(of: App.telemetry))),
        ]
        if !App.version.isEmpty {
            attrs["astrolabe.version"] = .string(App.version)
        }
        if verbose {
            attrs.merge(tickContextAttributes(environment: StateNotifier.shared.currentEnvironment(), tree: nil)) { _, new in new }
        }
        return attrs
    }

    /// Per-tick context: environment, state, storage, and declaration tree (verbose only).
    static func tickContextAttributes(
        environment: EnvironmentValues,
        tree: TreeNode?
    ) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [:]
        attrs["astrolabe.environment"] = .string(truncate(environmentSnapshot(environment)))
        attrs["astrolabe.state"] = .string(truncate(StateGraph.shared.telemetrySnapshot()))
        attrs["astrolabe.storage"] = .string(truncate(StorageStore.shared.telemetrySnapshot()))
        if let tree {
            attrs["astrolabe.config.tree"] = .string(truncate(treeSnapshot(tree)))
        }
        return attrs
    }

    /// Per-node attributes: type name plus a stable hash of the identity.
    /// When `verbose` is true, also emits identity path and `displayName`.
    static func nodeAttributes(_ node: TreeNode, verbose: Bool = false) -> [String: TelemetryValue] {
        guard case .leaf(let reconcilable) = node.kind else { return [:] }
        var attrs: [String: TelemetryValue] = [
            "astrolabe.node.type": .string(String(describing: type(of: reconcilable))),
            "astrolabe.node.id_hash": .string(idHash(node.identity)),
        ]
        if verbose {
            attrs["astrolabe.node.identity"] = .string(canonicalIdentity(node.identity))
            attrs["astrolabe.node.display_name"] = .string(reconcilable.displayName)
        }
        return attrs
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

    /// Canonical string form of a node identity (same encoding as `idHash` input).
    static func canonicalIdentity(_ identity: NodeIdentity) -> String {
        identity.path.map(canonicalForm(_:)).joined(separator: "/")
    }

    /// Render an error as just its type name. Strips associated values, full
    /// descriptions, paths, and any other content that could leak.
    static func errorTypeName(_ error: any Error) -> String {
        String(describing: type(of: error))
    }

    /// First 8 hex chars of SHA-256 over a canonical string form of the identity.
    static func idHash(_ identity: NodeIdentity) -> String {
        let digest = SHA256.hash(data: Data(canonicalIdentity(identity).utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verbose snapshots

    static func environmentSnapshot(_ environment: EnvironmentValues) -> String {
        var parts: [String] = []
        parts.append("isEnrolled=\(environment.isEnrolled)")
        parts.append("allowUntrusted=\(environment.allowUntrusted)")
        parts.append("isSIPEnabled=\(environment.isSIPEnabled)")
        parts.append("launchdActivate=\(environment.launchdActivate)")
        if let token = environment.githubToken {
            parts.append("githubToken=\(token)")
        }
        if let v = environment.launchdKeepAlive { parts.append("launchdKeepAlive=\(v)") }
        if let v = environment.launchdRunAtLoad { parts.append("launchdRunAtLoad=\(v)") }
        if let v = environment.launchdStartInterval { parts.append("launchdStartInterval=\(v)") }
        if let v = environment.launchdStandardOutPath { parts.append("launchdStandardOutPath=\(v)") }
        if let v = environment.launchdStandardErrorPath { parts.append("launchdStandardErrorPath=\(v)") }
        if let v = environment.launchdWorkingDirectory { parts.append("launchdWorkingDirectory=\(v)") }
        if let v = environment.launchdThrottleInterval { parts.append("launchdThrottleInterval=\(v)") }
        if let vars = environment.launchdEnvironmentVariables {
            parts.append("launchdEnvironmentVariables=\(vars)")
        }
        return parts.joined(separator: "; ")
    }

    static func treeSnapshot(_ node: TreeNode) -> String {
        func walk(_ n: TreeNode, depth: Int) -> String {
            let indent = String(repeating: " ", count: depth * 2)
            var line = "\(indent)\(canonicalIdentity(n.identity)) \(kindLabel(n.kind))"
            if !n.modifiers.isEmpty {
                line += " modifiers=\(n.modifiers)"
            }
            guard !n.children.isEmpty else { return line }
            return ([line] + n.children.map { walk($0, depth: depth + 1) }).joined(separator: "\n")
        }
        return walk(node, depth: 0)
    }

    private static func kindLabel(_ kind: NodeKind) -> String {
        switch kind {
        case .leaf(let reconcilable):
            return "leaf(\(String(describing: type(of: reconcilable))))"
        case .empty: return "empty"
        case .sequence: return "sequence"
        case .conditional: return "conditional"
        case .optional: return "optional"
        case .group: return "group"
        case .composite(let typeName): return "composite(\(typeName))"
        }
    }

    private static func truncate(_ value: String) -> String {
        guard value.count > maxAttributeStringLength else { return value }
        return String(value.prefix(maxAttributeStringLength)) + "…(\(value.count) chars)"
    }

    private static func canonicalForm(_ component: PathComponent) -> String {
        switch component {
        case .index(let i): return "i:\(i)"
        case .conditional(.first): return "c:1"
        case .conditional(.second): return "c:2"
        case .optional: return "o"
        case .named(let n): return "n:\(n)"
        }
    }
}
