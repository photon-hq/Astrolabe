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
/// Pkg(MyProvider())
/// ```
public protocol PackageProvider: Sendable {
    /// Installs the package.
    func install() async throws
}

/// Declares that a package should be installed via a `PackageProvider`.
///
/// `Pkg` is a leaf declaration — it has no body. The framework reconciles it
/// by calling the provider's `install()` method.
///
/// ```swift
/// Pkg(.catalog(.homebrew))
/// Pkg(.catalog(.commandLineTools))
/// Pkg(.gitHub("org/tool"))
/// Pkg(.gitHub("org/tool", version: .tag("v2.0")))
/// Pkg(MyCustomProvider())
/// ```
public struct Pkg<Provider: PackageProvider>: Setup {
    public typealias Body = Never

    public let provider: Provider

    public init(_ provider: Provider) {
        self.provider = provider
    }
}
