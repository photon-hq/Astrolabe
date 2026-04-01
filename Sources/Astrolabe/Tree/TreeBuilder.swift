/// Builds a `TreeNode` hierarchy from a `Setup` declaration.
///
/// Walks the `Setup` hierarchy recursively, expanding composite `body` properties
/// until reaching leaf nodes (`Body == Never`). Structural types (`SetupSequence`,
/// `ConditionalSetup`, etc.) are destructured by the framework.
public struct TreeBuilder {

    /// Builds a tree from a root setup declaration.
    public static func build<S: Setup>(_ setup: S, environment: EnvironmentValues = .init()) -> TreeNode {
        return EnvironmentValues.$current.withValue(environment) {
            _build(setup, path: [], environment: environment)
        }
    }

    // MARK: - Internal

    static func _build<S: Setup>(_ setup: S, path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        // Check for structural types using the internal protocol
        if let expandable = setup as? any _TreeExpandable {
            return expandable._buildTree(path: path, environment: environment)
        }

        // Leaf node: Body == Never
        if S.Body.self == Never.self {
            return _buildLeaf(setup, path: path, environment: environment)
        }

        // Composite: connect @State properties, then evaluate body
        let identity = NodeIdentity(path)
        StateGraph.shared.connect(setup, at: identity)

        let child = EnvironmentValues.$current.withValue(environment) { setup.body }
        return _build(child, path: path, environment: environment)
    }

    static func _buildLeaf<S: Setup>(_ setup: S, path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let kind: NodeKind

        if let brew = setup as? Brew {
            let brewType: NodeKind.BrewInfo.BrewType = switch brew.type {
            case .formula: .formula
            case .cask: .cask
            }
            kind = .brew(NodeKind.BrewInfo(name: brew.name, type: brewType))
        } else if let sysLeaf = setup as? any _SysLeaf {
            kind = sysLeaf._nodeKind
        } else if let pkgLeaf = setup as? any _PkgLeaf {
            kind = pkgLeaf._nodeKind
        } else if setup is Anchor {
            kind = .anchor
        } else if setup is EmptySetup {
            kind = .empty
        } else {
            kind = .composite(typeName: String(describing: type(of: setup)))
        }

        return TreeNode(
            identity: NodeIdentity(path),
            kind: kind
        )
    }
}

// MARK: - Internal Protocol for Pkg Type Erasure

/// Extracts `NodeKind` from a generic `Pkg<Provider>` without knowing `Provider`.
protocol _PkgLeaf {
    var _nodeKind: NodeKind { get }
}

extension Pkg: _PkgLeaf {
    var _nodeKind: NodeKind {
        if let catalog = provider as? CatalogPackage {
            let item: NodeKind.PkgInfo.PkgSource.CatalogItem = switch catalog.item {
            case .homebrew: .homebrew
            case .commandLineTools: .commandLineTools
            }
            return .pkg(NodeKind.PkgInfo(source: .catalog(item)))
        } else if let github = provider as? GitHubPackage {
            let version: NodeKind.PkgInfo.PkgSource.GitHubVersion = switch github.version {
            case .latest: .latest
            case .tag(let t): .tag(t)
            }
            let asset: NodeKind.PkgInfo.PkgSource.GitHubAsset = switch github.asset {
            case .pkg: .pkg
            case .filename(let f): .filename(f)
            case .regex(let r): .regex(r)
            }
            return .pkg(NodeKind.PkgInfo(source: .gitHub(repo: github.repo, version: version, asset: asset)))
        } else {
            return .pkg(NodeKind.PkgInfo(source: .custom(typeName: String(describing: type(of: provider)))))
        }
    }
}

// MARK: - Internal Protocol for Sys Type Erasure

/// Extracts `NodeKind` from a generic `Sys<Setting>` without knowing `Setting`.
protocol _SysLeaf {
    var _nodeKind: NodeKind { get }
}

extension Sys: _SysLeaf {
    var _nodeKind: NodeKind {
        if let hostname = setting as? HostnameSetting {
            return .sys(NodeKind.SysInfo(source: .hostname(name: hostname.name)))
        } else {
            return .sys(NodeKind.SysInfo(source: .custom(typeName: String(describing: type(of: setting)))))
        }
    }
}

// MARK: - Internal Protocol for Structural Types

/// Framework-internal protocol for types the tree builder knows how to destructure.
protocol _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode
}

// MARK: - SetupSequence

extension SetupSequence: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        var children: [TreeNode] = []
        var index = 0
        for step in repeat each steps {
            let child = TreeBuilder._build(step, path: path + [.index(index)], environment: environment)
            children.append(child)
            index += 1
        }
        return TreeNode(
            identity: NodeIdentity(path),
            kind: .sequence,
            children: children
        )
    }
}

// MARK: - ConditionalSetup

extension ConditionalSetup: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let child: TreeNode
        switch self {
        case .first(let setup):
            child = TreeBuilder._build(setup, path: path + [.conditional(.first)], environment: environment)
        case .second(let setup):
            child = TreeBuilder._build(setup, path: path + [.conditional(.second)], environment: environment)
        }
        return TreeNode(
            identity: NodeIdentity(path),
            kind: .conditional,
            children: [child]
        )
    }
}

// MARK: - OptionalSetup

extension OptionalSetup: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        var children: [TreeNode] = []
        if let wrapped {
            let child = TreeBuilder._build(wrapped, path: path + [.optional], environment: environment)
            children.append(child)
        }
        return TreeNode(
            identity: NodeIdentity(path),
            kind: .optional,
            children: children
        )
    }
}

// MARK: - ModifiedContent

extension ModifiedContent: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        var env = environment
        // Apply environment modifier if applicable
        if let envMod = modifier as? any _EnvironmentApplicable {
            envMod._apply(to: &env)
        }

        // Build the content subtree
        var node = EnvironmentValues.$current.withValue(env) {
            TreeBuilder._build(content, path: path, environment: env)
        }

        // Collect modifier metadata
        var modifiers = node.modifiers
        if let retryMod = modifier as? RetryModifier {
            modifiers.append(.retry(count: retryMod.count, delaySeconds: retryMod.delay.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }))
        }
        if let onFailMod = modifier as? OnFailModifier {
            ModifierStore.shared.appendOnFail(onFailMod, for: node.identity)
        }
        if let taskMod = modifier as? TaskModifier {
            ModifierStore.shared.appendTask(taskMod, for: node.identity)
        }
        if let dialogMod = modifier as? DialogModifier {
            ModifierStore.shared.appendDialog(dialogMod, for: node.identity)
        }
        if modifier is any _EnvironmentApplicable {
            modifiers.append(.environment(key: ""))
        }

        node = TreeNode(
            identity: node.identity,
            kind: node.kind,
            modifiers: modifiers,
            children: node.children
        )
        return node
    }
}

/// Internal protocol for environment modifiers that can apply their value.
protocol _EnvironmentApplicable {
    func _apply(to environment: inout EnvironmentValues)
}

extension EnvironmentModifier: _EnvironmentApplicable {
    func _apply(to environment: inout EnvironmentValues) {
        apply(to: &environment)
    }
}
