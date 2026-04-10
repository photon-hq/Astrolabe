# Astrolabe Constitution

Astrolabe is a declarative macOS configuration framework. You describe the desired state of a machine; the framework continuously converges reality to match.

This document captures the fundamental design decisions and invariants. If something here changes, the project is a different project. Don't update this for API additions, new node types, or implementation refactors — only for shifts in the core model.

---

## Three Principles

Everything follows from these. Every design decision must trace back to one of them.

### 1. The body is a pure function of state

`body` is evaluated, never executed. Same state in, same tree out. No side effects during evaluation. Side effects happen *after*, in async tasks spawned by the synchronous `tick()`.

### 2. Declare what, not when

The consumer never says "install wget now." They say "wget should be installed." The framework decides when and how. If it's already there, nothing happens. If the declaration disappears, the framework removes it.

The consumer thinks in nouns (what should exist), not verbs (what to do).

### 3. Separate scope by lifecycle

Three concerns, three lifecycles, never mixed:

| Scope | Lifetime | Triggers |
|-------|----------|----------|
| **State** | Re-derived each tick | Tree recalculation |
| **Declaration** | Ephemeral — rebuilt each tick | Task spawning via set diff |
| **Execution** | Long-lived, persisted | System changes |

State changes trigger tree recalculation. Tree changes trigger task spawning. Tasks write results to persistent storage. **The arrows never reverse.** Execution results never trigger tree recalculation. The tree never reads execution state.

This is the Kubernetes controller pattern: desired state vs observed state vs in-flight work. The controller compares desired vs observed, spawns work to close the gap, and returns immediately.

---

## The Loop

```
State Sources → Stores → tick() (sync) → Execution (async)
```

`tick()` is synchronous. Zero `await` points. It reads state, builds the tree, diffs against the previous tree, and enqueues async work. That's it.

Each tick:

1. Read state (already current — no polling inside tick)
2. Build tree from `body`
3. Diff current leaf identities vs previous leaf identities
4. Enqueue async mount/unmount for additions/removals
5. Persist current identities + execution records to disk

### Why tick() is synchronous

- No interleaving — two state changes can never produce partially-evaluated trees
- No deadlocks — no async coordination between declaration and execution
- Predictable ordering — state → tree → diff → enqueue, always
- Zero suspension points — spawns work, never waits

This is possible because tick only touches state (read-only) and declarations (pure computation). All slow work runs in detached async tasks.

---

## SwiftUI as the Model

Astrolabe mirrors SwiftUI's programming model deliberately. `Setup` is `View`. `Astrolabe` is `App`. `@SetupBuilder` is `@ViewBuilder`. `@State` is position-keyed. `Never` body terminates recursion. The result builder produces structural types (`SetupSequence`, `ConditionalSetup`, `OptionalSetup`).

If you're wondering "how should X work," the answer is almost always "how does SwiftUI do it."

---

## Identity

**Content IS identity.** Leaf nodes with inherent content — package names, daemon labels — use content-based identity, not positional index. `Brew("htop")` is always `brew:formula:htop` regardless of where it sits. Reordering siblings never shifts identities.

Structural types (sequences, conditionals, optionals) use positional identity for their container structure. This mirrors SwiftUI: `Identifiable` for data-driven views, structural identity for static hierarchies.

---

## State Model

Two stores, one notification channel.

- **StateNotifier** — holds environment values (written by providers), owns the notification stream that triggers `tick()`
- **StateGraph** — position-keyed `@State` storage (like SwiftUI's attribute graph)

Both route change notifications through the StateNotifier. Only *actual* value changes trigger `tick()` — same-value writes are no-ops.

### Three state types

| Type | Keyed by | Persisted | Written by | Triggers tick |
|------|----------|-----------|------------|---------------|
| `@State` | Tree position | No | Consumer | Yes (if changed) |
| `@Storage` | Explicit string key | Yes (disk) | Consumer | Yes (if changed) |
| `@Environment` | Key path | No (re-derived) | Providers | Yes (if changed) |

`@State` resets on restart. `@Storage` survives restart. `@Environment` is re-derived from system state — the system is the source of truth.

`@Storage` uses explicit string keys because persistent data must survive declaration rearrangements. Move a `@Storage` property to a different composite, the key stays the same. This is the contract between code and disk.

---

## Execution Records (PayloadStore)

A pure database. Maps node identity to what the Reconciler did (formula names, installed file lists, etc.). Used only for unmount — knowing *how* to reverse an installation.

**Separate from the tree.** The tree is what you declared; the PayloadStore is what the system reported. Different sources of truth, different lifecycles, different failure modes. The tree is ephemeral (rebuilt each tick). Payloads cannot be reconstructed from code. PayloadStore changes **never** trigger tree recalculation.

---

## Persistent Storage (StorageStore)

User-facing persistent state via `@Storage`. **Separate from PayloadStore** — different writer (consumer vs Reconciler), different trigger behavior (triggers tick vs doesn't). **Separate from StateGraph** — different key scheme (string vs position), different lifetime (persistent vs ephemeral).

Separate stores for separate lifecycles.

---

## Task Queue and Tree Diff

```
to_mount   = current_leaves − previous_leaves − in_flight
to_unmount = previous_leaves − current_leaves − in_flight
```

Set math. Additions trigger mount. Removals trigger unmount. In-flight work is skipped. Previous identities are persisted to disk so removals survive daemon restart.

Identity-keyed deduplication: one task per identity. If it's already in-flight, skip it.

---

## Reconciler

The Reconciler is domain-agnostic. It owns retry logic, error handling, and callback dispatch. It does **not** know how to install anything.

Each leaf node type carries its own lifecycle via a reconciliation protocol — `mount()` and `unmount()` with default no-op implementations. The Reconciler calls them without knowing what it's talking to. One protocol, one dispatch path.

**Adding a new node type requires zero changes to the Reconciler.** Define the declaration, conform to the reconciliation protocol, done.

### Error handling

Errors never crash, never corrupt persistent state. A failed mount leaves no record — the next tick sees it as "desired but not mounted" and re-enqueues. Retry is handled within each task, not by the tick loop.

---

## Modifiers

Metadata on declarations, not tree nodes. Like SwiftUI's `.alert`, `.task`, `.font`.

### Two storage paths (immutable rule)

Closure-bearing modifiers can't be serialized. They live in a side table (rebuilt every tick). Serializable modifiers (pure data) live on tree nodes. Environment modifiers propagate down the tree.

This split exists because closures aren't `Codable`. Don't try to unify them.

### Dialog every-tick evaluation

`.dialog(isPresented:)` is checked every tick, not just on mount. Matches SwiftUI's `.alert` semantics. State-driven, not event-driven.

### Uninstall callback snapshotting

When a node leaves the tree, its callbacks are already gone from the side table (rebuilt for current tree). Callbacks for removed nodes must be snapshotted *before* rebuilding.

---

## Concurrency

NSLock, not Swift actors. `tick()` must be synchronous — actor isolation requires `await`. Locks give synchronous thread-safe access from the sync tick while remaining safe for concurrent access from async tasks.

Homebrew cannot run parallel operations (lockfile). All brew operations are serialized through a semaphore. Everything else runs in parallel.

---

## Deployment

Runs as a root LaunchDaemon. Persistent — launchd restarts it on exit. On restart: load persisted state, build fresh tree, converge.

Homebrew refuses root. All brew commands execute as the console user via `sudo -u <username>`.

---

## Platform

- macOS 14+ (parameter packs)
- Swift 6.2+
- All types `Sendable` — strict concurrency
