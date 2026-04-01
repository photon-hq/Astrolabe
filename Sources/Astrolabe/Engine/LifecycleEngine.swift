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
public final class LifecycleEngine<Configuration: Astrolabe>: Sendable {
    private let configuration: Configuration
    private let providers: [any StateProvider]
    private let pollInterval: Duration
    private let persistence: Persistence
    private let payloadStore: PayloadStore
    private let taskQueue: TaskQueue
    private let reconciler: Reconciler

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
        self.taskQueue = TaskQueue()
        self.reconciler = Reconciler()
    }

    /// Runs the lifecycle loop. Returns when a termination signal is received.
    public func run() async throws {
        // Setup persistence
        try persistence.ensureDirectory()
        persistence.loadPayloads(into: payloadStore)

        // Lifecycle: onStart
        try await configuration.onStart()

        // Initial tick — always runs once on startup
        tick()

        // Run the loop until SIGTERM/SIGINT
        let loopTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // Poll providers periodically, notify only on change
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: self.pollInterval)
                        var env = EnvironmentValues()
                        var changed = false
                        for provider in self.providers {
                            if provider.check(updating: &env) {
                                changed = true
                            }
                        }
                        if changed {
                            StateTracker.shared.notifyChange()
                        }
                    }
                }

                // Single consumer: tick on any state change
                group.addTask {
                    for await _ in StateTracker.shared.changes {
                        self.tick()
                    }
                }
            }
        }

        // Wait for termination signal, then cancel the loop
        await awaitTerminationSignal()
        loopTask.cancel()
        await loopTask.value

        // Lifecycle: onExit
        configuration.onExit()
    }

    /// Fully synchronous — build tree, diff against observed state, enqueue work.
    private func tick() {
        // 1. Poll providers (get current state)
        var environment = EnvironmentValues()
        for provider in providers {
            _ = provider.check(updating: &environment)
        }

        // 2. Build tree (pure declarations, no status)
        let tree = EnvironmentValues.$current.withValue(environment) {
            TreeBuilder.build(configuration, environment: environment)
        }

        // 3. Diff desired vs observed
        let leaves = tree.leaves()
        let desiredIdentities = Set(leaves.map(\.identity))
        let installed = payloadStore.allIdentities()
        let inFlight = taskQueue.inFlightIdentities()

        // Install: desired but not installed and not in-flight
        for leaf in leaves {
            if !installed.contains(leaf.identity) && !inFlight.contains(leaf.identity) {
                taskQueue.enqueueInstall(
                    identity: leaf.identity,
                    node: leaf,
                    reconciler: reconciler,
                    payloadStore: payloadStore
                )
            }
        }

        // Uninstall: installed but no longer desired and not in-flight
        for id in installed {
            if !desiredIdentities.contains(id) && !inFlight.contains(id) {
                taskQueue.enqueueUninstall(
                    identity: id,
                    reconciler: reconciler,
                    payloadStore: payloadStore
                )
            }
        }

        // 4. Persist PayloadStore (best-effort)
        try? payloadStore.save(to: Persistence.payloadURL)
    }

    // MARK: - Signal Handling

    /// Suspends until SIGTERM or SIGINT is received.
    private func awaitTerminationSignal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)

            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM)
            sigterm.setEventHandler { continuation.resume() }
            sigterm.resume()

            let sigint = DispatchSource.makeSignalSource(signal: SIGINT)
            sigint.setEventHandler { continuation.resume() }
            sigint.resume()
        }
    }
}
