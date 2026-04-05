import Darwin
import Foundation

/// The main event loop that drives Astrolabe's declarative convergence.
///
/// Lifecycle:
/// 1. Load persistence
/// 2. `onStart()` — async setup
/// 3. Initial `tick()`
/// 4. Loop (poll + state changes) until SIGTERM/SIGINT
/// 5. `onExit()` — sync cleanup
///
/// `tick()` is fully synchronous — no `await`, no suspension, no interleaving.
/// Async work (installs, downloads) runs in detached tasks via `TaskQueue`.
public final class LifecycleEngine<Configuration: Astrolabe>: @unchecked Sendable {
    private let configuration: Configuration
    private let providers: [any StateProvider]
    private let pollInterval: Duration
    private let persistence: Persistence
    private let taskQueue: TaskQueue
    private let reconciler: Reconciler
    private let stateNotifier: StateNotifier
    private let modifierStore: ModifierStore
    private var previousIdentities: Set<NodeIdentity>
    /// Leaf nodes from the previous tick, keyed by identity — used for node-based unmount.
    private var previousLeaves: [NodeIdentity: TreeNode] = [:]
    /// Identities seen in previous ticks during THIS run only. Never persisted.
    private var previousTaskIdentities: Set<NodeIdentity> = []
    /// Running `.task {}` modifier closures, keyed by the identity they're attached to.
    private var modifierTasks: [NodeIdentity: Task<Void, Never>] = [:]
    /// Dialogs currently being presented, to avoid duplicate presentations across ticks.
    private var activeDialogs: Set<NodeIdentity> = []
    /// Stored previous values for `.onChange(of:)` modifiers, keyed by node identity.
    private var onChangeValues: [NodeIdentity: [any Sendable]] = [:]

    public init(
        configuration: Configuration,
        providers: [any StateProvider],
        pollInterval: Duration,
        stateNotifier: StateNotifier = .shared
    ) {
        self.configuration = configuration
        self.providers = providers
        self.pollInterval = pollInterval
        self.persistence = Persistence()
        self.taskQueue = TaskQueue()
        self.reconciler = Reconciler()
        self.stateNotifier = stateNotifier
        self.modifierStore = ModifierStore.shared
        self.previousIdentities = Persistence.loadIdentities()
    }

    /// Runs the lifecycle loop. Returns when a termination signal is received.
    public func run() async throws {
        // Setup persistence
        try persistence.ensureDirectory()
        persistence.loadPayloads(into: PayloadStore.shared)
        StorageStore.shared.load()

        // Seed previousLeaves from persisted identities + payload records
        // so that cross-restart unmount works via node.unmount().
        for identity in previousIdentities {
            if let record = PayloadStore.shared.record(for: identity) {
                previousLeaves[identity] = TreeNode(
                    identity: identity,
                    kind: .leaf(record.reconcilableNode())
                )
            }
        }

        // Lifecycle: onStart
        try await configuration.onStart()

        // Seed environment before first tick
        _ = stateNotifier.updateEnvironment(from: providers)

        // Initial tick — always runs once on startup
        tick()

        // Run the loop until SIGTERM/SIGINT
        let loopTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // Poll providers periodically, write to StateNotifier
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: self.pollInterval)
                        if self.stateNotifier.updateEnvironment(from: self.providers) {
                            self.stateNotifier.notifyChange()
                        }
                    }
                }

                // Single consumer: tick on any state change
                group.addTask {
                    for await _ in self.stateNotifier.changes {
                        self.tick()
                    }
                }
            }
        }

        // Wait for termination signal, then shut down
        await awaitTerminationSignal()
        loopTask.cancel()
        configuration.onExit()
        exit(0)
    }

    /// Fully synchronous — build tree, diff against previous tree, enqueue work.
    private func tick() {
        // 1. Read current state (no polling — StateNotifier already has it)
        let environment = stateNotifier.currentEnvironment()

        // 2. Build tree (pure declarations, connects @State via Mirror).
        //    Snapshot uninstall callbacks before clearing — nodes leaving the tree
        //    won't have entries after rebuild, but their hooks must still fire.
        var previousCallbacks: [NodeIdentity: ModifierStore.Callbacks] = [:]
        for id in previousIdentities {
            if let cb = modifierStore.callbacks(for: id) {
                previousCallbacks[id] = cb
            }
        }
        modifierStore.clear()
        let tree = EnvironmentValues.$current.withValue(environment) {
            TreeBuilder.build(configuration, environment: environment)
        }

        // 3. Evaluate onChange modifiers — compare current values against stored previous
        let leaves = tree.leaves()
        for leaf in leaves {
            guard let callbacks = modifierStore.callbacks(for: leaf.identity),
                  !callbacks.onChanges.isEmpty else { continue }
            let prevValues = onChangeValues[leaf.identity] ?? []
            var newValues: [any Sendable] = []
            for (i, onChange) in callbacks.onChanges.enumerated() {
                let prev = i < prevValues.count ? prevValues[i] : nil
                newValues.append(onChange._execute(previousValue: prev))
            }
            onChangeValues[leaf.identity] = newValues
        }

        // 4. Diff current tree vs previous tree
        let currentIdentities = Set(leaves.map(\.identity))
        let inFlight = taskQueue.inFlightIdentities()

        // Mount: in current tree but not in previous (persisted), and not in-flight
        let mountAdditions = currentIdentities.subtracting(previousIdentities).subtracting(inFlight)
        var mountByPriority: [Int: [TaskQueue.PrioritizedWork]] = [:]
        for leaf in leaves where mountAdditions.contains(leaf.identity) {
            let callbacks = modifierStore.callbacks(for: leaf.identity)
            let priority = callbacks?.priority ?? Int.max
            let work = TaskQueue.PrioritizedWork(
                identity: leaf.identity,
                node: leaf,
                callbacks: callbacks,
                priority: priority
            )
            mountByPriority[priority, default: []].append(work)
        }
        if !mountByPriority.isEmpty {
            let sortedGroups = mountByPriority.keys.sorted().map { mountByPriority[$0]! }
            taskQueue.enqueuePriorityMounts(
                groups: sortedGroups,
                reconciler: reconciler,
                payloadStore: PayloadStore.shared
            )
        }

        // Task additions: in current tree but not in previous tick THIS run (ephemeral).
        // Grouped by priority — lower priority tasks start first, higher ones wait.
        let taskAdditions = currentIdentities.subtracting(previousTaskIdentities)
        var tasksByPriority: [Int: [(NodeIdentity, [TaskModifier])]] = [:]
        for leaf in leaves where taskAdditions.contains(leaf.identity) {
            if let callbacks = modifierStore.callbacks(for: leaf.identity), !callbacks.tasks.isEmpty {
                let priority = callbacks.priority ?? Int.max
                tasksByPriority[priority, default: []].append((leaf.identity, callbacks.tasks))
            }
        }

        if !tasksByPriority.isEmpty {
            let sortedPriorities = tasksByPriority.keys.sorted()

            // Build group signals and register identities
            var groupSignals: [GroupSignal] = []
            for priority in sortedPriorities {
                let group = tasksByPriority[priority]!
                let signal = GroupSignal(count: group.count)
                groupSignals.append(signal)
                for (id, _) in group {
                    PriorityGate.shared.register(id, signal: signal)
                }
            }

            // Start first group immediately, chain the rest via a coordinator
            let firstGroup = tasksByPriority[sortedPriorities[0]]!
            for (id, taskMods) in firstGroup {
                for taskMod in taskMods {
                    modifierTasks[id] = Task {
                        await taskMod.action()
                    }
                }
            }

            if sortedPriorities.count > 1 {
                let remainingPriorities = Array(sortedPriorities.dropFirst())
                let tasksByPriorityCopy = tasksByPriority
                Task { [weak self] in
                    for (i, priority) in remainingPriorities.enumerated() {
                        // Wait for previous group to finish first iteration
                        await groupSignals[i].wait()
                        // Start this group's tasks
                        let group = tasksByPriorityCopy[priority]!
                        for (id, taskMods) in group {
                            for taskMod in taskMods {
                                self?.modifierTasks[id] = Task {
                                    await taskMod.action()
                                }
                            }
                        }
                    }
                }
            }
        }

        // Unmount: in previous tree but not in current, and not in-flight
        let mountRemovals = previousIdentities.subtracting(currentIdentities).subtracting(inFlight)
        var unmountByPriority: [Int: [TaskQueue.PrioritizedWork]] = [:]
        for id in mountRemovals {
            guard let previousNode = previousLeaves[id] else { continue }
            let callbacks = previousCallbacks[id]
            let priority = callbacks?.priority ?? Int.max
            let work = TaskQueue.PrioritizedWork(
                identity: id,
                node: previousNode,
                callbacks: callbacks,
                priority: priority
            )
            unmountByPriority[priority, default: []].append(work)
        }
        if !unmountByPriority.isEmpty {
            let sortedGroups = unmountByPriority.keys.sorted(by: >).map { unmountByPriority[$0]! }
            taskQueue.enqueuePriorityUnmounts(
                groups: sortedGroups,
                reconciler: reconciler,
                payloadStore: PayloadStore.shared
            )
        }

        // Task removals: cancel .task {} closures for nodes gone this tick
        let taskRemovals = previousTaskIdentities.subtracting(currentIdentities)
        for id in taskRemovals {
            modifierTasks.removeValue(forKey: id)?.cancel()
            onChangeValues.removeValue(forKey: id)
        }

        // Dialogs: check ALL current leaves every tick (like SwiftUI re-evaluates .alert on every render)
        for leaf in leaves {
            guard let callbacks = modifierStore.callbacks(for: leaf.identity) else { continue }
            for dialog in callbacks.dialogs where dialog.isPresented.wrappedValue {
                guard !activeDialogs.contains(leaf.identity) else { continue }
                activeDialogs.insert(leaf.identity)
                let title = dialog.title
                let message = dialog.message
                let buttons = dialog.buttons
                let binding = dialog.isPresented
                let identity = leaf.identity
                Task { [weak self] in
                    let d = Dialog(title, message: message, buttons: buttons)
                    try? await d.present()
                    binding.wrappedValue = false
                    self?.activeDialogs.remove(identity)
                }
            }
        }

        // List dialogs: same pattern as dialogs
        for leaf in leaves {
            guard let callbacks = modifierStore.callbacks(for: leaf.identity) else { continue }
            for listDialog in callbacks.listDialogs where listDialog.isPresented.wrappedValue {
                guard !activeDialogs.contains(leaf.identity) else { continue }
                activeDialogs.insert(leaf.identity)
                let prompt = listDialog.prompt
                let items = listDialog.items
                let defaultItems = listDialog.defaultItems
                let multipleSelection = listDialog.multipleSelection
                let binding = listDialog.isPresented
                let onSelection = listDialog.onSelection
                let identity = leaf.identity
                Task { [weak self] in
                    let ld = ListDialog(
                        prompt: prompt,
                        items: items,
                        defaultItems: defaultItems,
                        multipleSelection: multipleSelection
                    )
                    if let selected = try? await ld.present() {
                        onSelection(selected)
                    }
                    binding.wrappedValue = false
                    self?.activeDialogs.remove(identity)
                }
            }
        }

        // Clean up activeDialogs for nodes no longer in tree
        activeDialogs = activeDialogs.intersection(currentIdentities)

        // 4. Update previous and persist (best-effort)
        previousLeaves = Dictionary(uniqueKeysWithValues: leaves.map { ($0.identity, $0) })
        previousTaskIdentities = currentIdentities
        previousIdentities = currentIdentities
        try? Persistence.saveIdentities(currentIdentities)
        try? PayloadStore.shared.save(to: Persistence.payloadURL)
    }

    // MARK: - Signal Handling

    /// Suspends until SIGTERM or SIGINT is received.
    private func awaitTerminationSignal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)

            let lock = NSLock()
            var resumed = false

            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT)

            func handleSignal() {
                let shouldResume = lock.withLock {
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                if shouldResume {
                    sigterm.cancel()
                    sigint.cancel()
                    continuation.resume()
                }
            }

            sigterm.setEventHandler { handleSignal() }
            sigint.setEventHandler { handleSignal() }
            sigterm.resume()
            sigint.resume()
        }
    }
}
