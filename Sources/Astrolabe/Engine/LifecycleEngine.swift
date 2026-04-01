import Foundation

/// The main event loop that drives Astrolabe's declarative convergence.
///
/// Each cycle:
/// 1. Poll state providers → update environment
/// 2. Evaluate body → produce new tree
/// 3. Diff new tree vs previous tree
/// 4. Reconcile in parallel
/// 5. Persist tree + payload store
public final class LifecycleEngine<Configuration: Astrolabe>: Sendable {
    private let configuration: Configuration
    private let providers: [any StateProvider]
    private let pollInterval: Duration
    private let persistence: Persistence
    private let payloadStore: PayloadStore
    private let treeStore: TreeStore

    public init(
        configuration: Configuration,
        providers: [any StateProvider],
        pollInterval: Duration
    ) {
        self.configuration = configuration
        self.providers = providers
        self.pollInterval = pollInterval
        self.persistence = Persistence()
        self.payloadStore = PayloadStore()
        self.treeStore = TreeStore()
    }

    /// Runs the lifecycle loop forever. Never returns under normal operation.
    public func run() async throws {
        // Setup persistence
        try persistence.ensureDirectory()
        await persistence.loadPayloads(into: payloadStore)

        // Load previous tree
        if let previous = persistence.loadTree() {
            await treeStore.set(previous)
        }

        // Initial tick
        await tick()

        // Run the loop
        await withTaskGroup(of: Void.self) { group in
            // Poll loop
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: self.pollInterval)
                    await self.tick()
                }
            }

            // State change listener
            group.addTask {
                for await _ in StateTracker.shared.changes {
                    await self.tick()
                }
            }
        }
    }

    private func tick() async {
        // 1. Poll providers
        var environment = EnvironmentValues()
        for provider in providers {
            provider.check(updating: &environment)
        }

        // 2. Evaluate body
        let newTree = EnvironmentValues.$current.withValue(environment) {
            TreeBuilder.build(configuration, environment: environment)
        }

        // 3. Diff
        let previousTree = await treeStore.current
        let actions = TreeDiff.diff(old: previousTree, new: newTree)

        // 4. Reconcile
        let engine = ReconciliationEngine(payloadStore: payloadStore)
        let statuses = await engine.reconcile(actions)

        // 5. Update tree statuses
        var updatedTree = newTree
        updateStatuses(&updatedTree, from: statuses)

        // 6. Persist
        await treeStore.set(updatedTree)
        do {
            try persistence.saveTree(updatedTree)
            try await persistence.savePayloads(payloadStore)
        } catch {
            print("[Astrolabe] Failed to persist state: \(error)")
        }
    }

    private func updateStatuses(_ node: inout TreeNode, from statuses: [NodeIdentity: NodeStatus]) {
        if let status = statuses[node.identity] {
            node.status = status
        }
        for i in node.children.indices {
            updateStatuses(&node.children[i], from: statuses)
        }
    }
}

/// Actor-isolated storage for the previous tree, ensuring safe concurrent access.
private actor TreeStore {
    var current: TreeNode?

    func set(_ tree: TreeNode) {
        current = tree
    }
}
