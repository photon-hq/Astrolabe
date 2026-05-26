import CryptoKit
import Foundation

/// Centralized constructors for telemetry attribute dicts.
///
/// All instrumentation call sites in Astrolabe core build attributes through
/// these helpers. Direct `[String: TelemetryValue]` literals at call sites
/// are forbidden by review convention — this file is the single place where
/// the privacy policy is enforced.
enum TelemetryAttributes {

    /// Top-level run-span attributes. Pulls operational metadata only.
    static func runAttributes<App: Astrolabe>(_ appType: App.Type) -> [String: TelemetryValue] {
        var attrs: [String: TelemetryValue] = [
            "astrolabe.daemon_mode": .bool(App.daemonMode),
            "telemetry.backend": .string(String(describing: type(of: App.telemetry))),
        ]
        if !App.version.isEmpty {
            attrs["astrolabe.version"] = .string(App.version)
        }
        return attrs
    }

    /// Per-node attributes: type name plus a stable hash of the identity.
    /// When `verbose` is true, also emits `astrolabe.node.identity` (canonical path).
    /// Returns an empty dict for non-leaf nodes (defensive — instrumentation
    /// only fires on leaves in practice).
    static func nodeAttributes(_ node: TreeNode, verbose: Bool = false) -> [String: TelemetryValue] {
        guard case .leaf(let reconcilable) = node.kind else { return [:] }
        var attrs: [String: TelemetryValue] = [
            "astrolabe.node.type": .string(String(describing: type(of: reconcilable))),
            "astrolabe.node.id_hash": .string(idHash(node.identity)),
        ]
        if verbose {
            attrs["astrolabe.node.identity"] = .string(canonicalIdentity(node.identity))
        }
        return attrs
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
    /// Stable across runs and across Swift versions; not reversible to the
    /// original name.
    static func idHash(_ identity: NodeIdentity) -> String {
        let digest = SHA256.hash(data: Data(canonicalIdentity(identity).utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
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
