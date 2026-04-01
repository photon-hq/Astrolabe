/// An action produced by diffing two trees.
public enum DiffAction: Sendable {
    /// A new leaf node appeared — install it.
    case install(TreeNode)
    /// A leaf node disappeared — uninstall it.
    case uninstall(NodeIdentity)
    /// A leaf node is unchanged — no action needed.
    case unchanged(TreeNode)
}

/// Diffs two declaration trees by structural identity.
///
/// Compares leaf nodes between old and new trees. Produces install/uninstall/unchanged
/// actions for the reconciler.
public struct TreeDiff {

    /// Diffs an old tree against a new tree, returning actions for each leaf.
    public static func diff(old: TreeNode?, new: TreeNode) -> [DiffAction] {
        let oldLeaves = old?.leaves() ?? []
        let newLeaves = new.leaves()

        let oldByIdentity = Dictionary(oldLeaves.map { ($0.identity, $0) }, uniquingKeysWith: { _, new in new })
        let newByIdentity = Dictionary(newLeaves.map { ($0.identity, $0) }, uniquingKeysWith: { _, new in new })

        var actions: [DiffAction] = []

        // New or unchanged
        for leaf in newLeaves {
            if let oldLeaf = oldByIdentity[leaf.identity] {
                // Existed before — carry forward status
                var updated = leaf
                updated.status = oldLeaf.status
                actions.append(.unchanged(updated))
            } else {
                // New leaf — needs installation
                actions.append(.install(leaf))
            }
        }

        // Removed
        for leaf in oldLeaves where newByIdentity[leaf.identity] == nil {
            actions.append(.uninstall(leaf.identity))
        }

        return actions
    }
}
