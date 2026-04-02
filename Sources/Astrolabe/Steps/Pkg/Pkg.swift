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

extension Pkg: Installable {}

extension Pkg: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        if let catalog = provider as? CatalogPackage {
            let item: PkgInfo.PkgSource.CatalogItem = switch catalog.item {
            case .homebrew: .homebrew
            case .commandLineTools: .commandLineTools
            }
            return PkgInfo(source: .catalog(item))
        } else if let github = provider as? GitHubPackage {
            let version: PkgInfo.PkgSource.GitHubVersion = switch github.version {
            case .latest: .latest
            case .tag(let t): .tag(t)
            }
            let asset: PkgInfo.PkgSource.GitHubAsset = switch github.asset {
            case .pkg: .pkg
            case .filename(let f): .filename(f)
            case .regex(let r): .regex(r)
            }
            return PkgInfo(source: .gitHub(repo: github.repo, version: version, asset: asset))
        } else {
            return PkgInfo(source: .custom(typeName: String(describing: type(of: provider))))
        }
    }
}
