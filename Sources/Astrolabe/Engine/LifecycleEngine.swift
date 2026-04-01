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
    private let payloadStore: PayloadStore
    private let taskQueue: TaskQueue
    private let reconciler: Reconciler
    private let stateNotifier: StateNotifier
    private var previousIdentities: Set<NodeIdentity>

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
        self.payloadStore = PayloadStore()
        self.taskQueue = TaskQueue()
        self.reconciler = Reconciler()
        self.stateNotifier = stateNotifier
        self.previousIdentities = Persistence.loadIdentities()
    }

    /// Runs the lifecycle loop. Returns when a termination signal is received.
    public func run() async throws {
        // Setup persistence
        try persistence.ensureDirectory()
        persistence.loadPayloads(into: payloadStore)

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

        // 2. Build tree (pure declarations, connects @State via Mirror)
        let tree = EnvironmentValues.$current.withValue(environment) {
            TreeBuilder.build(configuration, environment: environment)
        }

        // 3. Diff current tree vs previous tree
        let leaves = tree.leaves()
        let currentIdentities = Set(leaves.map(\.identity))
        let inFlight = taskQueue.inFlightIdentities()

        // Install: in current tree but not in previous, and not in-flight
        let additions = currentIdentities.subtracting(previousIdentities).subtracting(inFlight)
        for leaf in leaves where additions.contains(leaf.identity) {
            taskQueue.enqueueInstall(
                identity: leaf.identity,
                node: leaf,
                reconciler: reconciler,
                payloadStore: payloadStore
            )
        }

        // Uninstall: in previous tree but not in current, and not in-flight
        let removals = previousIdentities.subtracting(currentIdentities).subtracting(inFlight)
        for id in removals {
            taskQueue.enqueueUninstall(
                identity: id,
                reconciler: reconciler,
                payloadStore: payloadStore
            )
        }

        // 4. Update previous and persist (best-effort)
        previousIdentities = currentIdentities
        try? Persistence.saveIdentities(currentIdentities)
        try? payloadStore.save(to: Persistence.payloadURL)
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
