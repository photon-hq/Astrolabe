/// Marker protocol for declarations that participate in install/uninstall reconciliation.
///
/// Lifecycle hooks (`.preInstall {}`, `.postInstall {}`, `.preUninstall {}`,
/// `.postUninstall {}`) are available on all `Setup` types and propagate to
/// descendant leaves. This protocol serves as a semantic marker for types
/// that directly reconcile system state (e.g. `Brew`, `Pkg`, `LaunchDaemon`,
/// `LaunchAgent`).
public protocol Installable: Setup {}
