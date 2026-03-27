/// A provider that knows how to install a package.
///
/// Conform to this protocol to add custom package sources:
///
/// ```swift
/// struct MyProvider: PackageProvider {
///     func install() async throws {
///         // custom installation logic
///     }
/// }
///
/// Package(MyProvider())
/// ```
public protocol PackageProvider: Sendable {
    /// Installs the package.
    func install() async throws
}
