/// The kind of declaration a tree node represents.
public enum NodeKind: Equatable, Codable, Sendable {
    case brew(BrewInfo)
    case pkg(PkgInfo)
    case sys(SysInfo)
    case anchor
    case empty
    case sequence
    case conditional
    case optional
    case group
    case composite(typeName: String)

    /// Metadata for a `Brew` leaf node.
    public struct BrewInfo: Equatable, Codable, Sendable {
        public let name: String
        public let type: BrewType

        public enum BrewType: String, Equatable, Codable, Sendable {
            case formula
            case cask
        }
    }

    /// Metadata for a `Pkg<Provider>` leaf node.
    public struct PkgInfo: Equatable, Codable, Sendable {
        public let source: PkgSource

        public enum PkgSource: Equatable, Codable, Sendable {
            case catalog(CatalogItem)
            case gitHub(repo: String, version: GitHubVersion, asset: GitHubAsset)
            case custom(typeName: String)

            public enum CatalogItem: String, Equatable, Codable, Sendable {
                case homebrew
                case commandLineTools
            }

            public enum GitHubVersion: Equatable, Codable, Sendable {
                case latest
                case tag(String)
            }

            public enum GitHubAsset: Equatable, Codable, Sendable {
                case pkg
                case filename(String)
                case regex(String)
            }
        }
    }
    /// Metadata for a `Sys<Setting>` leaf node.
    public struct SysInfo: Equatable, Codable, Sendable {
        public let source: SysSource

        public enum SysSource: Equatable, Codable, Sendable {
            case hostname(name: String)
            case custom(typeName: String)
        }
    }
}

/// Modifier metadata stored on tree nodes.
public enum NodeModifier: Codable, Sendable {
    case retry(count: Int, delaySeconds: Double?)
    case allowUntrusted
    case environment(key: String)
}

/// A node in the declaration tree.
///
/// The tree is a pure snapshot of the body evaluation — it contains only
/// what the code declares. Runtime artifacts live in the `PayloadStore`.
public struct TreeNode: Codable, Sendable {
    public let identity: NodeIdentity
    public let kind: NodeKind
    public let modifiers: [NodeModifier]
    public var children: [TreeNode]

    public init(
        identity: NodeIdentity,
        kind: NodeKind,
        modifiers: [NodeModifier] = [],
        children: [TreeNode] = []
    ) {
        self.identity = identity
        self.kind = kind
        self.modifiers = modifiers
        self.children = children
    }
}

extension TreeNode {
    /// Collects all leaf nodes (nodes without children) from this subtree.
    public func leaves() -> [TreeNode] {
        if children.isEmpty {
            return [self]
        }
        return children.flatMap { $0.leaves() }
    }

    /// Finds a node by identity.
    public func find(_ target: NodeIdentity) -> TreeNode? {
        if identity == target { return self }
        for child in children {
            if let found = child.find(target) { return found }
        }
        return nil
    }
}
