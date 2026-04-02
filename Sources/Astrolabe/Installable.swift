/// Marker protocol for package-like declarations that support install/uninstall lifecycle hooks.
///
/// Conforming types gain access to `.preInstall {}`, `.postInstall {}`,
/// `.preUninstall {}`, `.postUninstall {}`, and `.allowUntrusted()`.
public protocol Installable: Setup {}
