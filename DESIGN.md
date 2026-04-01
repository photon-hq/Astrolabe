# Astrolabe Design

Astrolabe is a declarative macOS configuration framework. You describe the desired state of a machine — what packages should be installed, what conditions gate them — and the framework continuously converges reality to match your declaration.

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    @State var showWelcome = true
    @Environment(\.isEnrolled) var isEnrolled
    @Environment(\.consoleUser) var consoleUser

    var body: some Setup {
        Pkg(.catalog(.commandLineTools))
        Pkg(.catalog(.homebrew))
        Pkg("wget")

        if isEnrolled {
            Pkg("git-lfs")
            Pkg(.gitHub("org/internal-tool"))
                .retry(3)
                .onFail { error in reportToMDM(error) }
        }

        if let user = consoleUser {
            Pkg("iterm2", type: .cask)
            Pkg("firefox", type: .cask)
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

The `body` property is evaluated — never executed. Given the same state, it always produces the same declaration tree. There are no side effects during evaluation. Side effects happen during _reconciliation_, after the tree has been diffed.

This is the quantum analogy: the body describes all possible configurations simultaneously (every `if` branch, every conditional `Pkg`). State collapses it into one concrete tree — the current desired state. Change the state, re-evaluate, get a different tree. The tree is the observation; the body is the wave function.

### 2. Declare what, not when

The consumer never says "install wget now." They say "wget should be installed." The framework decides when and how. If wget is already installed, nothing happens. If wget's declaration disappears from the body, the framework uninstalls it.

This inverts control. In an imperative system, the consumer drives execution. In a declarative system, the consumer describes the end state, and the framework continuously drives reality toward it. The consumer thinks in _nouns_ (what should exist), not _verbs_ (what to do).

### 3. Separate what you know from what you learn

The declaration tree is derived from code — deterministic, reproducible, 1:1 with the source. Runtime artifacts (which files a `.pkg` installed, what `pkgutil` reported) are learned during reconciliation. These live in separate stores because they have different lifecycles, different sources of truth, and different failure modes.

The tree can always be reconstructed from code + state. Payloads cannot — they come from the system. Mixing them violates the purity of the tree and makes it impossible to reason about what the code declares vs what the system did.

### Derived patterns

Every design decision traces back to these three principles:

| Pattern | Follows from |
|---------|-------------|
| State changes trigger re-evaluation, not manual calls | Body is a pure function of state |
| `Pkg` installs _and_ uninstalls based on presence in tree | Declare what, not when |
| Tree persists separately from payload store | Separate what you know from what you learn |
| `@State` is ephemeral; `@Environment` is re-derived each tick | Body is a pure function of state |
| Reconciliation is parallel | Declare what, not when (no ordering implied) |
| Errors never crash, never corrupt the tree | Tree is declarations (always valid); errors are reconciliation artifacts |
| `.dialog(isPresented:)` is a modifier, not a node | Declare what, not when (dialog is a side effect of state) |
| Type IS identity (structural position in the tree) | Body is a pure function of state (same code = same identity) |

## Architecture

### The Loop

```
State Sources                    Engine                        Output
─────────────                    ──────                        ──────

┌──────────┐   state change   ┌────────────┐
│ Registry │─────────────────▶│ Re-evaluate│──▶ new tree
│ (poll 5s)│                  │    body    │        │
└──────────┘                  └────────────┘        ▼
                                              ┌──────────┐   ┌───────────┐
┌──────────┐   state change                   │   Diff   │──▶│ Reconcile │
│  @State  │─────────────────────────────────▶│ old tree │   │ (parallel)│
│ mutation │                                  │ vs new   │   └─────┬─────┘
└──────────┘                                  └──────────┘         │
                                                             ┌─────▼─────┐
┌──────────┐   state change                                  │  Persist  │
│ External │────────────────────────────────────────────────▶│tree+payloads│
│  events  │                                                 └───────────┘
└──────────┘
```

The poll loop is one source of state changes — it runs the registry (enrollment check, console user check) every N seconds. But any state mutation (`@State`, external event) also triggers re-evaluation. The loop and re-evaluation are decoupled.

Each cycle:

1. **State changes** — from registry tick, `@State` mutation, or external event
2. **Re-evaluate body** — call `body` with current state → produce declaration tree
3. **Diff** — compare new tree against previous tree by structural identity
4. **Reconcile** — apply delta in parallel (install new packages, uninstall removed ones, show dialogs)
5. **Persist** — save tree + payload store to disk

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
| View tree → Render tree | Declaration tree → Reconciliation | Evaluate then diff |

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
public struct Pkg: Setup {
    public typealias Body = Never
}
```

Like SwiftUI's `Text`, `Color`, `Image`.

### Composite setups — have a `body`

Composites combine other setups. The framework calls `body` to expand them.

```swift
struct DevTools: Setup {
    var body: some Setup {
        Pkg("wget")
        Pkg("git-lfs")
        Pkg("swiftformat")
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
    associatedtype Body: Setup
    @SetupBuilder var body: Body { get }
    init()
    var pollInterval: Duration { get }  // default: .seconds(5)
}
```

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

The poll loop iterates registered providers. Each provider checks the system and updates environment values:

```swift
protocol StateProvider: Sendable {
    func check(updating environment: inout EnvironmentValues)
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
| Tree | Yes (disk) | Body evaluation — for diffing after restart |
| Payload store | Yes (disk) | Runtime artifacts — for uninstall |

## Two Stores

### Tree — Pure Declaration Snapshot

Direct 1:1 mirror of the body evaluation. Contains ONLY what the code declares. No runtime data. Deterministic: same code + same state = same tree. Always.

```
Tree Node {
    identity    // structural position + type
    kind        // pkg, group, conditional, ...
    status      // pending, applied
    modifiers   // retry config, onFail config, dialog metadata
    children    // child nodes
}
```

Persisted to disk. On restart, the previous tree is loaded so the framework can diff against the new evaluation and know what changed.

### Payload Store — Runtime Artifacts

Separate from the tree. Maps declaration identity → runtime data produced during reconciliation. Written on install, read on uninstall.

```
identity → {
    type: .brew(formula: "wget")
        | .pkg(id: "com.org.tool", files: ["/usr/local/bin/tool", ...])
        | .cask(name: "firefox")
    installedAt: Date
}
```

For `.pkg` packages: `pkgutil --files <pkg-id>` captures the full file list after install. On uninstall: remove those files, then `pkgutil --forget <pkg-id>`.

For Homebrew: store formula/cask name. On uninstall: `brew uninstall <name>`.

### Why separate

The tree is what you _declared_. The payload store is what the _system reported_. They have different sources of truth, different lifecycles, and different failure modes. The tree can always be reconstructed from code. Payloads cannot.

Both persisted at `/Library/Application Support/Astrolabe/`.

### Restart lifecycle

1. Load previous tree + payload store from disk
2. Poll registry → update environment
3. Evaluate body → produce new tree
4. Diff new tree vs previous tree → reconcile (payload store provides uninstall info)
5. Save both to disk

## Declarations

### `Pkg`

Declares that a package should be installed. Convergent: if it appears, the framework installs it. If it disappears, the framework uninstalls it.

```swift
Pkg("wget")                            // Homebrew formula (default)
Pkg("firefox", type: .cask)           // Homebrew cask
Pkg(.catalog(.homebrew))              // Well-known catalog package
Pkg(.catalog(.commandLineTools))      // Xcode Command Line Tools
Pkg(.gitHub("org/tool"))              // GitHub release .pkg
Pkg(.gitHub("org/tool", version: .tag("v2.0")))
Pkg(.gitHub("org/tool", asset: .regex(".*arm64.*\\.pkg")))
```

### Mutual exclusivity

```swift
if useChrome {
    Pkg("google-chrome", type: .cask)
} else {
    Pkg("firefox", type: .cask)
}
```

When the condition flips: diff detects Chrome added, Firefox removed. Reconciler installs Chrome, uninstalls Firefox. Only one exists at a time.

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
        Pkg("swiftformat")
        Pkg("swiftlint")
        Pkg("git-lfs")
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

## Modifiers

### `.dialog(isPresented:)` — State-Bound Presentation

Not a tree node. Metadata on the declaration it modifies. Like SwiftUI's `.alert(isPresented:)`.

```swift
@State var showWelcome = true

Pkg("iterm2", type: .cask)
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

### `.onFail {}` — Error Callback

```swift
Pkg("wget")
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

## Reconciliation

### Parallel by default

All leaf node reconciliation runs in parallel. No implied ordering between declarations.

```swift
// These install concurrently
Pkg("wget")
Pkg("git-lfs")
Pkg("firefox", type: .cask)
```

### Error handling — never crash

All reconciliation is wrapped in error handling. A failed install never crashes the daemon, never corrupts the tree.

**Failed reconciliation does NOT affect the tree.** The tree reflects what's _declared_, not what _succeeded_. A failed `Pkg` stays as `.pending` — the next tick retries it (or `.retry()` handles it).

### Diffing

Compare old tree vs new tree by structural identity:

| Old Tree | New Tree | Action |
|----------|----------|--------|
| — | `Pkg("wget")` | Install, write payload |
| `Pkg("wget")` | `Pkg("wget")` | No-op |
| `Pkg("wget")` | — | Uninstall via payload store |

## Deployment

Astrolabe runs as a long-running daemon. On first run, it self-registers a LaunchDaemon (`codes.photon.astrolabe`) with `KeepAlive: true` and `RunAtLoad: true`.

The `main()` entry point:

1. Root check (UID 0)
2. Install LaunchDaemon if not present
3. Start lifecycle engine (poll loop in background)
4. Evaluate body → initial tree
5. Diff against persisted tree → reconcile
6. Loop: state changes → re-evaluate → diff → reconcile

The daemon is persistent. If it exits, launchd restarts it. On restart, it loads the previous tree from disk and diffs against a fresh evaluation — converging reality to the current declaration.

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
| `consoleUser` | `ConsoleUser?` | Registry (framework-managed) |

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
