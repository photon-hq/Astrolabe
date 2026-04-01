# Astrolabe Design

Astrolabe is a declarative macOS configuration framework. You describe the desired state of a machine — what packages should be installed, what conditions gate them — and the framework continuously converges reality to match your declaration.

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    @State var showWelcome = true
    @Environment(\.isEnrolled) var isEnrolled
    @Environment(\.consoleUser) var consoleUser

    init() {
        Self.pollInterval = .seconds(10)
    }

    func onStart() async throws {
        // Async setup before first tick: fetch config, authenticate, etc.
    }

    var body: some Setup {
        Pkg(.catalog(.commandLineTools))
        Pkg(.catalog(.homebrew))
        Brew("wget")

        if isEnrolled {
            Brew("git-lfs")
            Pkg(.gitHub("org/internal-tool"))
                .retry(3)
                .onFail { error in reportToMDM(error) }
        }

        if let user = consoleUser {
            Brew("iterm2", type: .cask)
            Brew("firefox", type: .cask)
                .dialog("Welcome, \(user.name)!",
                        message: "Your Mac is ready.",
                        isPresented: $showWelcome) {
                    Button("Get Started")
                }
        }
    }
}
```

## Meta

The design rests on three first principles. Everything else follows.

### 1. The body is a pure function of state

The `body` property is evaluated — never executed. Given the same state, it always produces the same declaration tree. There are no side effects during evaluation. Side effects happen _after_ evaluation, in async tasks spawned by the synchronous `tick()`.

This is the quantum analogy: the body describes all possible configurations simultaneously (every `if` branch, every conditional declaration). State collapses it into one concrete tree — the current desired state. Change the state, re-evaluate, get a different tree. The tree is the observation; the body is the wave function.

### 2. Declare what, not when

The consumer never says "install wget now." They say "wget should be installed." The framework decides when and how. If wget is already installed, nothing happens. If wget's declaration disappears from the body, the framework uninstalls it.

This inverts control. In an imperative system, the consumer drives execution. In a declarative system, the consumer describes the end state, and the framework continuously drives reality toward it. The consumer thinks in _nouns_ (what should exist), not _verbs_ (what to do).

### 3. Separate scope by lifecycle

Three concerns have different lifecycles and must never be mixed:

| Scope | Contains | Lifetime | Triggers |
|-------|----------|----------|----------|
| **State** | User-defined state, environment values | Re-derived each tick | Tree recalculation |
| **Declaration** | Tree of desired state | Ephemeral — rebuilt each tick | Task spawning (set diff) |
| **Execution** | In-flight tasks, payload records | Long-lived, persisted | System changes |

State changes trigger tree recalculation. Tree changes trigger task spawning. Tasks write to the payload store. But the arrows never reverse: payload changes never trigger tree recalculation. The tree never reads execution state. This separation is what makes `tick()` synchronous — it only touches state and declarations, never waits on execution.

This follows the Kubernetes controller pattern: desired state (tree) vs observed state (payload store) vs in-flight work (task queue). The controller (tick) compares desired vs observed, spawns work to close the gap, and returns immediately.

### Derived patterns

Every design decision traces back to these three principles:

| Pattern | Follows from |
|---------|-------------|
| State changes trigger re-evaluation, not manual calls | Body is a pure function of state |
| Declarations install _and_ uninstall based on presence in tree | Declare what, not when |
| Tree is ephemeral; only PayloadStore persists | Separate scope by lifecycle |
| `@State` is ephemeral; `@Environment` is re-derived each tick | Body is a pure function of state |
| `tick()` is synchronous — async work spawned, not awaited | Separate scope by lifecycle |
| Payload changes never trigger tree recalculation | Separate scope by lifecycle |
| TreeNode has no status field | Nodes are pure declarations, not execution state |
| Errors never crash, never corrupt the tree | Tree is declarations (always valid); errors are execution artifacts |
| `.dialog(isPresented:)` is a modifier, not a node | Declare what, not when (dialog is a side effect of state) |
| Type IS identity (structural position in the tree) | Body is a pure function of state (same code = same identity) |
| TaskQueue deduplicates by identity | Declare what, not when (one task per desired outcome) |

## Architecture

### The Loop

```
State Sources                    Engine (sync tick)             Execution (async)
─────────────                    ──────────────────             ─────────────────

┌──────────┐   state change   ┌────────────┐
│ Registry │─────────────────▶│  Evaluate  │──▶ declaration tree
│ (poll Ns)│                  │    body    │        │
└──────────┘                  └────────────┘        ▼
                                              ┌──────────┐   ┌───────────┐
┌──────────┐   state change                   │ Set Diff │   │ TaskQueue │
│  @State  │─────────────────────────────────▶│ desired  │──▶│  enqueue  │──▶ async Tasks
│ mutation │                                  │ vs store │   │ (sync)    │       │
└──────────┘                                  └──────────┘   └───────────┘       │
                                                                            ┌─────▼─────┐
                                                                            │ Reconciler│
                                                                            │ (install/ │
                                                                            │ uninstall)│
                                                                            └─────┬─────┘
                                                                                  │
                                                                            ┌─────▼──────┐
                                                                            │PayloadStore│
                                                                            │  (persist) │
                                                                            └────────────┘
```

The engine is structured around a synchronous `tick()` that builds the tree, diffs it against observed state, and enqueues work — all with zero `await` points. Async work (downloads, installs) runs in detached tasks that write back to the PayloadStore on completion.

Each tick:

1. **Poll providers** — read current system state into environment
2. **Build tree** — call `body` with current state → produce declaration tree
3. **Set diff** — compare tree leaves vs PayloadStore + TaskQueue identities
4. **Enqueue tasks** — spawn async install/uninstall for any delta (returns immediately)
5. **Persist** — save PayloadStore to disk (best-effort)

The poll loop runs providers every N seconds. If any provider detects a change (returns `true`), it notifies the engine, which runs `tick()`. State mutations (`@State`) also trigger `tick()`. But `tick()` itself is always synchronous.

### Why tick() is synchronous

A synchronous tick guarantees:

- **No interleaving** — two state changes can never produce partially-evaluated trees
- **No deadlocks** — no async coordination between declaration and execution
- **Predictable ordering** — state → tree → diff → enqueue, always in that order
- **Zero suspension points** — the tick reads state and spawns work, but never waits

This is possible because the tick only touches two things: state (read-only) and declarations (pure computation). All slow work — downloads, installs, process spawning — happens in the execution scope, in async tasks that run independently.

### SwiftUI Mapping

| SwiftUI | Astrolabe | Role |
|---------|-----------|------|
| `App` | `Astrolabe` | Entry point protocol |
| `View` | `Setup` | Declaration protocol |
| `@ViewBuilder` | `@SetupBuilder` | Result builder DSL |
| `Never` body | `Never` body | Leaf node terminator |
| `TupleView` | `SetupSequence` | Multiple declarations in a block |
| `_ConditionalContent` | `ConditionalSetup` | `if/else` branches |
| `Optional<Content>` | `OptionalSetup` | `if` without `else` |
| `EmptyView` | `EmptySetup` | Empty body |
| `Group` | `Group` | Transparent grouping |
| `ScenePhase` | `\.isEnrolled`, `\.consoleUser` | Framework-managed environment state |
| `@State` | `@State` | Ephemeral local state |
| `@Environment` | `@Environment` | Read-only framework state |
| `.alert(isPresented:)` | `.dialog(isPresented:)` | State-bound presentation |
| `.task {}` | `.task {}` | Lifecycle-bound async side effect |
| Render loop | Lifecycle engine | Framework-owned loop |
| View tree → Render tree | Declaration tree → Set diff → Tasks | Evaluate then reconcile |

## `Setup` Protocol

The fundamental building block. Mirrors SwiftUI's `View` — requires only `body`.

```swift
public protocol Setup: Sendable {
    associatedtype Body: Setup
    @SetupBuilder var body: Body { get }
}
```

### Leaf nodes — `Body == Never`

Leaf nodes are concrete declarations. They represent actual desired state and have no `body`. `Never` breaks the recursion — the framework stops walking and reconciles directly.

```swift
public struct Brew: Setup {
    public typealias Body = Never
}
```

Like SwiftUI's `Text`, `Color`, `Image`.

### Composite setups — have a `body`

Composites combine other setups. The framework calls `body` to expand them.

```swift
struct DevTools: Setup {
    var body: some Setup {
        Brew("wget")
        Brew("git-lfs")
        Brew("swiftformat")
    }
}
```

Like custom SwiftUI views.

### Structural types

Produced by `@SetupBuilder`. The framework knows how to walk into each one:

- **`SetupSequence<each S>`** — multiple declarations (like `TupleView`)
- **`ConditionalSetup<T, F>`** — `if/else` branches (like `_ConditionalContent`)
- **`OptionalSetup<T>`** — `if` without else
- **`EmptySetup`** — empty body

**Type IS identity.** The Swift type system encodes the tree structure at compile time. Position + type determines identity — no edit-distance algorithm needed. Same code produces same identity. This is why the body must be a pure function of state.

### `Astrolabe` Protocol

The entry point. Like SwiftUI's `App`.

```swift
public protocol Astrolabe: Setup {
    init()
    func onStart() async throws
    func onExit()
}
```

- **`init()`** — set static configuration (e.g., `Self.pollInterval = .seconds(10)`)
- **`onStart()`** — async setup after persistence loads, before the first tick. Fetch config, authenticate, pre-clean state
- **`onExit()`** — sync cleanup when SIGTERM/SIGINT is received. Keep it fast
- **`pollInterval`** — static property (default 5s), set in `init()`, not a protocol requirement

Only the top-level type uses `@main`. Conforms to `Setup` so it can be nested as a reusable module.

## State System

### `@State` — Ephemeral Local State

In-memory only. Resets on daemon restart. Mutations trigger body re-evaluation.

```swift
@State var showWelcome = true
```

The consumer owns it. The framework watches it.

### `@Environment` — Framework-Managed State

Read-only for consumers. The registry re-derives these from the actual system each tick — no persistence needed because the system IS the source of truth.

```swift
@Environment(\.isEnrolled) var isEnrolled
@Environment(\.consoleUser) var consoleUser
```

On restart, the registry checks the system and repopulates. Nothing to persist.

### Registry — Extensible State Providers

The poll loop iterates registered providers. Each provider checks the system, updates environment values, and reports whether anything changed:

```swift
public protocol StateProvider: Sendable {
    @discardableResult
    func check(updating environment: inout EnvironmentValues) -> Bool
}
```

Returning `true` means the value changed since the last check — the engine re-evaluates the tree. Returning `false` means no change — the engine skips the tick. This change-detection avoids unnecessary re-evaluation.

Providers use `LockedValue<T>` for thread-safe change tracking:

```swift
struct NetworkProvider: StateProvider {
    let lastValue = LockedValue(false)

    func check(updating environment: inout EnvironmentValues) -> Bool {
        let current = checkNetwork()
        environment.isOnline = current
        return lastValue.exchange(current)  // true if value changed
    }
}
```

Built-in providers:

- **`EnrollmentProvider`** — checks `profiles status -type enrollment` → updates `\.isEnrolled`
- **`ConsoleUserProvider`** — checks `SCDynamicStoreCopyConsoleUser` → updates `\.consoleUser`

Extensible: add custom providers for network state, FileVault status, etc.

### What persists vs what doesn't

| Store | Persisted? | Source of truth |
|-------|-----------|-----------------|
| `@State` | No (memory only) | Consumer code |
| `@Environment` | No (re-derived each tick) | System state |
| Tree | No (rebuilt each tick) | Body evaluation — ephemeral |
| Payload store | Yes (disk) | Runtime artifacts — for uninstall |

## PayloadStore

The PayloadStore is a pure database — a thread-safe key-value map from `NodeIdentity` to `PayloadRecord`. It has no behavior beyond storage. Any part of the system can read or write it at any time. It participates in no update cycle and triggers no recalculation.

```swift
public final class PayloadStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NodeIdentity: PayloadRecord] = [:]

    func record(for identity: NodeIdentity) -> PayloadRecord?
    func set(_ record: PayloadRecord, for identity: NodeIdentity)
    func remove(for identity: NodeIdentity) -> PayloadRecord?
    func allIdentities() -> Set<NodeIdentity>
}
```

All methods are synchronous (lock-based, not actor-based) so they can be called from the sync `tick()`. Records capture runtime artifacts — what was installed, what type, when — separate from the declaration tree.

For Homebrew: store formula/cask name. On uninstall: `brew uninstall <name>`.

For `.pkg` packages: `pkgutil --files <pkg-id>` captures the full file list after install. On uninstall: remove those files, then `pkgutil --forget <pkg-id>`.

Persisted at `/Library/Application Support/Astrolabe/payloads.json`.

### Why PayloadStore is separate from the tree

The tree is what you _declared_. The PayloadStore is what the _system reported_. They have different sources of truth, different lifecycles, and different failure modes.

The tree can always be reconstructed from code + state — it is ephemeral, rebuilt fresh each tick. Payloads cannot be reconstructed — they come from the system. Mixing them would violate the purity of the tree and make it impossible to reason about what the code declares vs what the system did.

PayloadStore changes never trigger tree recalculation. The tree is a function of state, not payloads. This is the key invariant that keeps the three scopes separate.

## TaskQueue

The TaskQueue manages in-flight reconciliation work. It bridges the synchronous tick (which decides _what_ to do) and asynchronous execution (which _does_ it).

```swift
public final class TaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [NodeIdentity: Task<Void, Never>] = [:]

    func isInFlight(_ identity: NodeIdentity) -> Bool
    func inFlightIdentities() -> Set<NodeIdentity>
    func enqueueInstall(identity:, node:, reconciler:, payloadStore:)
    func enqueueUninstall(identity:, reconciler:, payloadStore:)
}
```

Key properties:

- **All public methods synchronous** — safe to call from `tick()`
- **Identity-keyed deduplication** — if a task for identity X is in-flight, `enqueue` is a no-op. This prevents duplicate installs across ticks
- **Async execution** — `enqueue` spawns a detached `Task` and returns immediately. The task self-removes on completion
- **Tick-aware** — `tick()` checks `inFlightIdentities()` to skip nodes with pending work

### Set Diff (replaces TreeDiff)

There is no tree diff algorithm. Instead, each tick performs a simple set comparison:

```
desired   = Set(tree.leaves().map(\.identity))
installed = payloadStore.allIdentities()
inFlight  = taskQueue.inFlightIdentities()

to install   = desired − installed − inFlight
to uninstall = installed − desired − inFlight
```

This is possible because the tree is ephemeral — there is no "previous tree" to diff against. The PayloadStore is the record of what's installed. The gap between desired and installed IS the work to do.

## Reconciler

The Reconciler performs actual system changes — installing and uninstalling packages. It is called by async tasks spawned from the TaskQueue, never from `tick()` directly.

### Brew operations

Brew operations have three safety measures:

1. **Console user context** — Homebrew refuses to run as root. The reconciler looks up the console user via `SCDynamicStoreCopyConsoleUser` and wraps all brew commands with `sudo -u <username>`
2. **Idempotency checks** — before installing, the reconciler checks:
   - `which <formula>` — catches formulas installed from any source
   - `brew list <name>` — catches brew-managed packages
   - If either succeeds, the package is marked installed in PayloadStore without running `brew install`
3. **Serialization** — brew cannot run multiple operations in parallel (lockfile conflicts). All brew operations are serialized via an `AsyncSemaphore` (from [`groue/Semaphore`](https://github.com/groue/Semaphore))

### Error handling — never crash

All reconciliation is wrapped in error handling. A failed install never crashes the daemon, never corrupts the PayloadStore.

Failed reconciliation leaves no PayloadStore entry — the next tick sees the identity as "desired but not installed" and re-enqueues it. The `.retry()` modifier controls how many attempts a single task makes before giving up.

### Retry logic

Retry is handled within each task, not by the tick loop. When a task is spawned, it reads the `.retry` modifier from the node and loops internally:

```
attempt 1 → fail → delay → attempt 2 → fail → delay → attempt 3 → give up
```

On exhaustion, the task removes itself from the TaskQueue. The next tick may re-enqueue it (starting fresh), or the consumer's `.onFail {}` handler runs.

## Declarations

### `Brew`

Declares that a Homebrew formula or cask should be installed.

```swift
Brew("wget")                           // Homebrew formula (default)
Brew("firefox", type: .cask)          // Homebrew cask
```

### `Pkg`

Declares that a package should be installed from a non-Homebrew source.

```swift
Pkg(.catalog(.homebrew))              // Well-known catalog package
Pkg(.catalog(.commandLineTools))      // Xcode Command Line Tools
Pkg(.gitHub("org/tool"))              // GitHub release .pkg
Pkg(.gitHub("org/tool", version: .tag("v2.0")))
Pkg(.gitHub("org/tool", asset: .regex(".*arm64.*\\.pkg")))
```

### Mutual exclusivity

```swift
if useChrome {
    Brew("google-chrome", type: .cask)
} else {
    Brew("firefox", type: .cask)
}
```

When the condition flips: set diff detects Chrome desired but not installed, Firefox installed but not desired. Reconciler installs Chrome, uninstalls Firefox. Only one exists at a time.

### Private repos

```swift
Group {
    Pkg(.gitHub("private/repo1"))
    Pkg(.gitHub("private/repo2"))
}
.environment(\.gitHubToken, ProcessInfo.processInfo.environment["GITHUB_TOKEN"])
```

### Composable configurations

```swift
struct DevTools: Setup {
    var body: some Setup {
        Brew("swiftformat")
        Brew("swiftlint")
        Brew("git-lfs")
    }
}

@main
struct MySetup: Astrolabe {
    @Environment(\.isEnrolled) var isEnrolled

    var body: some Setup {
        Pkg(.catalog(.homebrew))

        if isEnrolled {
            DevTools()
        }
    }
}
```

## Lifecycle

### Startup sequence

```
1. Root check (UID 0)
2. Install LaunchDaemon if not present
3. Load PayloadStore from disk (fallback to {})
4. onStart() — async setup
5. Initial tick()
6. Loop: poll providers + listen for state changes → tick()
```

### Signal handling

The engine installs handlers for SIGTERM and SIGINT via `DispatchSource`. When a signal arrives:

1. The poll/state loop is cancelled
2. `onExit()` is called (synchronous — keep it fast)
3. The process exits

### `onStart()` and `onExit()`

```swift
@main
struct MySetup: Astrolabe {
    init() {
        Self.pollInterval = .seconds(10)
    }

    func onStart() async throws {
        // Runs after persistence loads, before first tick.
        // Use for: fetching remote config, authenticating,
        // pre-cleaning state, removing packages.
    }

    func onExit() {
        // Runs when SIGTERM/SIGINT received.
        // Synchronous — keep it fast.
    }

    var body: some Setup { ... }
}
```

### Restart lifecycle

1. Load PayloadStore from disk (the tree is NOT persisted — it's rebuilt)
2. `onStart()` — async setup
3. Poll providers → update environment
4. Build tree → set diff against PayloadStore → enqueue tasks
5. Loop until terminated

The tree is ephemeral. On restart, a fresh tree is built from code + current state, and compared against the PayloadStore (the record of what's installed). There is no "previous tree" — the PayloadStore IS the memory of what was done.

## Modifiers

### `.dialog(isPresented:)` — State-Bound Presentation

Not a tree node. Metadata on the declaration it modifies. Like SwiftUI's `.alert(isPresented:)`.

```swift
@State var showWelcome = true

Brew("iterm2", type: .cask)
    .dialog("Welcome!", message: "Your Mac is ready.", isPresented: $showWelcome) {
        Button("Get Started")
    }
```

- `isPresented` is `true` → show dialog during reconciliation of this node
- User clicks button → binding set to `false` → state change → re-evaluation
- `@State` resets on restart → dialog shows again next launch

### `.task {}` — Lifecycle-Bound Async Work

Runs async work tied to a declaration's lifecycle. Like SwiftUI's `.task`.

```swift
Pkg(.catalog(.homebrew))
    .task {
        await setupBrewTaps()
    }
```

- Starts when declaration enters tree
- Cancelled when declaration leaves tree
- `.task(id:)` variant restarts when id changes

### `.retry()` — Retry on Failure

```swift
Pkg(.gitHub("org/tool"))
    .retry(3)                          // up to 3 attempts
    .retry(3, delay: .seconds(10))     // with delay between attempts
```

Retry is handled within the async task, not by the tick loop. The task reads the modifier and loops internally.

### `.onFail {}` — Error Callback

```swift
Brew("wget")
    .onFail { error in
        print("wget install failed: \(error)")
    }
```

### `.environment()` — Config Propagation

Sets an environment value for this declaration and all its children.

```swift
Group {
    Pkg(.gitHub("private/repo1"))
    Pkg(.gitHub("private/repo2"))
}
.environment(\.gitHubToken, token)
```

### `.allowUntrusted()` — Unsigned Packages

```swift
Pkg(.gitHub("owner/unsigned-tool"))
    .allowUntrusted()
```

## Concurrency Model

### Lock-based synchronous access

The PayloadStore, TaskQueue, and LockedValue all use `NSLock` instead of Swift actors. This is deliberate: `tick()` must be synchronous, and actor-isolated methods require `await`. Locks provide synchronous thread-safe access from the sync tick while remaining safe for concurrent access from async tasks.

```swift
// LockedValue — thread-safe change detection for StateProviders
final class LockedValue<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    @discardableResult
    func exchange(_ newValue: Value) -> Bool {
        lock.withLock {
            let changed = _value != newValue
            _value = newValue
            return changed
        }
    }
}
```

### Brew serialization

Homebrew cannot run multiple operations in parallel (lockfile conflicts). The reconciler uses an `AsyncSemaphore` (from [`groue/Semaphore`](https://github.com/groue/Semaphore)) to serialize all brew operations across concurrent tasks:

```swift
private let brewSemaphore = AsyncSemaphore(value: 1)

func installBrew(...) async {
    await brewSemaphore.wait()
    defer { brewSemaphore.signal() }
    // Only one brew operation runs at a time
}
```

Other package types (`.pkg`, GitHub downloads) run in parallel — only brew is serialized.

## Deployment

Astrolabe runs as a long-running daemon. On first run, it self-registers a LaunchDaemon (`codes.photon.astrolabe`) with `KeepAlive: true` and `RunAtLoad: true`.

The daemon is persistent. If it exits, launchd restarts it. On restart, it loads the PayloadStore from disk and builds a fresh tree — converging reality to the current declaration.

Because the daemon runs as root but Homebrew refuses to run as root, all brew commands are executed via `sudo -u <consoleUser>` using the current console user looked up via `SCDynamicStoreCopyConsoleUser`.

## Environment

SwiftUI-style environment for passing config down the declaration tree.

- **`EnvironmentKey`** — protocol defining a key + default value
- **`EnvironmentValues`** — key-value storage
- **`.environment(\.key, value)`** — modifier on any `Setup`
- Values propagate to children, don't leak to siblings
- Nested `.environment()` overrides outer values

**Built-in keys:**

| Key | Type | Source |
|-----|------|--------|
| `gitHubToken` | `String?` | Consumer-provided |
| `allowUntrusted` | `Bool` | Consumer-provided |
| `isEnrolled` | `Bool` | Registry (framework-managed) |
| `consoleUser` | `String?` | Registry (framework-managed) |

Custom keys:

```swift
struct MyKey: EnvironmentKey {
    static let defaultValue: String = ""
}
extension EnvironmentValues {
    var myValue: String {
        get { self[MyKey.self] }
        set { self[MyKey.self] = newValue }
    }
}
```

## Platform

- macOS 14+ (required for parameter packs)
- Swift 6.2+
- All types are `Sendable` for strict concurrency
- Dependencies: [`groue/Semaphore`](https://github.com/groue/Semaphore) for `AsyncSemaphore`
