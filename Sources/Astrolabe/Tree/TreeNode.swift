/// The kind of declaration a tree node represents.
public enum NodeKind: Sendable {
    /// A reconcilable leaf node — protocol-based, fully extensible.
    case leaf(any ReconcilableNode)

    /// An empty placeholder node.
    case empty

    // Framework-owned structural kinds (fixed).
    case sequence
    case conditional
    case optional
    case group
    case composite(typeName: String)
}

/// Modifier metadata stored on tree nodes.
public enum NodeModifier: Sendable {
    case retry(count: Int, delaySeconds: Double?)
    case allowUntrusted
    case environment(key: String)
}

/// A node in the declaration tree.
///
/// The tree is a pure snapshot of the body evaluation — it contains only
/// what the code declares. Runtime artifacts live in the `PayloadStore`.
public struct TreeNode: Sendable {
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

    /// Collects identities of all `.leaf`-kind descendant nodes.
    func leafIdentities() -> [NodeIdentity] {
        leaves().compactMap { node in
            if case .leaf = node.kind { return node.identity }
            return nil
        }
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
