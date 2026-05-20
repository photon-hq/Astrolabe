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
    /// Stable identity for this provider (used as the node's content-based identity).
    var id: String { get }
    /// Installs the package.
    func install() async throws
    /// Returns whether the package is currently installed.
    func isInstalled() async -> Bool
    /// The payload record to store for unmount cleanup. Return `nil` to skip.
    var payloadRecord: PayloadRecord? { get }
}

extension PackageProvider {
    public var id: String { String(describing: type(of: self)) }
    public func isInstalled() async -> Bool { true }
    public var payloadRecord: PayloadRecord? { nil }
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

// MARK: - Concrete Overloads (autocomplete hints for built-in providers)

extension Pkg where Provider == CatalogPackage {
    public init(_ provider: CatalogPackage) {
        self.provider = provider
    }
}

extension Pkg where Provider == GitHubPackage {
    public init(_ provider: GitHubPackage) {
        self.provider = provider
    }
}

extension Pkg: Installable {}

extension Pkg: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let identity = NodeIdentity([.named("pkg:\(provider.id)")])
        let provider = self.provider
        let info = PkgInfo(
            providerDescription: provider.id,
            install: { try await provider.install() },
            isInstalled: { await provider.isInstalled() },
            payloadRecord: provider.payloadRecord
        )
        return TreeNode(identity: identity, kind: .leaf(info))
    }
}
