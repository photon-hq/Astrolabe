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
    /// Returns an empty dict for non-leaf nodes (defensive — instrumentation
    /// only fires on leaves in practice).
    static func nodeAttributes(_ node: TreeNode) -> [String: TelemetryValue] {
        guard case .leaf(let reconcilable) = node.kind else { return [:] }
        return [
            "astrolabe.node.type": .string(String(describing: type(of: reconcilable))),
            "astrolabe.node.id_hash": .string(idHash(node.identity)),
        ]
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
        let canonical = identity.path.map(canonicalForm(_:)).joined(separator: "/")
        let digest = SHA256.hash(data: Data(canonical.utf8))
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
