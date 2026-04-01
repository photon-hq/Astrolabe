/// Metadata + reconciliation logic for a `Pkg` leaf node.
public struct PkgInfo: ReconcilableNode {
    public let source: PkgSource

    public enum PkgSource: Sendable {
        case catalog(CatalogItem)
        case gitHub(repo: String, version: GitHubVersion, asset: GitHubAsset)
        case custom(typeName: String)

        public enum CatalogItem: String, Sendable {
            case homebrew
            case commandLineTools
        }

        public enum GitHubVersion: Sendable {
            case latest
            case tag(String)
        }

        public enum GitHubAsset: Sendable {
            case pkg
            case filename(String)
            case regex(String)
        }
    }

    public var displayName: String {
        switch source {
        case .catalog(let i): "catalog \(i)"
        case .gitHub(let r, _, _): "github \(r)"
        case .custom(let t): "custom \(t)"
        }
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        switch source {
        case .catalog(let item):
            switch item {
            case .homebrew:
                try await CatalogPackage(.homebrew).install()
                context.payloadStore.set(.catalog(item: "homebrew"), for: identity)
            case .commandLineTools:
                try await CatalogPackage(.commandLineTools).install()
                context.payloadStore.set(.catalog(item: "commandLineTools"), for: identity)
            }
            print("[Astrolabe] Installed catalog \(item).")

        case .gitHub(let repo, let version, let asset):
            let ghVersion: GitHubPackage.Version = switch version {
            case .latest: .latest
            case .tag(let t): .tag(t)
            }
            let ghAsset: GitHubPackage.AssetFilter = switch asset {
            case .pkg: .pkg
            case .filename(let f): .filename(f)
            case .regex(let r): .regex(r)
            }
            let gh = GitHubPackage(repo: repo, version: ghVersion, asset: ghAsset)
            try await gh.install()
            context.payloadStore.set(.pkg(id: repo, files: []), for: identity)
            print("[Astrolabe] Installed github \(repo).")

        case .custom(let typeName):
            print("[Astrolabe] Cannot reconcile custom provider \(typeName) from persisted tree.")
        }
    }
}
