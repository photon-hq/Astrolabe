# The Loop Is The Retry

## Summary

Astrolabe previously exposed two convergence mechanisms that overlapped: an explicit `.retry(count, delay:)` modifier and the per-node drift loop. They answered the same question — "how many times will this try?" — with different counters, and surfacing both confused users.

This PR removes the explicit retry surface and the entire concept of mount **success** or **failure** from the Reconciler pipeline. `mount()` is now a wave of preparation work, `unmount()` is a wave of cleanup, and `loop()` is the only authority on whether reality matches the declaration. When the loop reports drift, the framework re-prepares. That is the retry — there is no other retry.

## What changed

- **Deleted** `RetryModifier` and `.retry()`.
- **Deleted** `OnFailModifier` and `.onFail()`. (Coming back in a follow-up PR with new semantics — see below.)
- **`Reconciler.mount` and `Reconciler.unmount` return `Void`.** No more `Bool` success signal. Inner `mount()`/`unmount()` may still throw; the Reconciler catches, logs via telemetry, and returns.
- **`TaskQueue.PrioritizedWork.onComplete`** is now `(@Sendable () async -> Void)?` — no `Bool` parameter, because there is no outcome to report.
- **`NodeModifier.retry` case removed**, plus the matching fields/setters in `ModifierStore.Callbacks` and the handling blocks in `TreeBuilder`.
- **README and CONSTITUTION** rewritten around the new mental model.

## The new mental model

```
mount()   = prepare. A wave of work. May no-op, may install, may throw partway.
unmount() = clean.   Symmetric. May throw. Best-effort.
loop()    = truth.   Returns .healthy or .drifted. The ONLY convergence signal.
```

- Errors in `mount`/`unmount` never crash, never corrupt persistent state. They are caught, logged, and otherwise ignored.
- A drifted node is re-prepared automatically at the cadence set by `.loopInterval(_:)` (default 15s, per-node configurable).
- `LoopSupervisor`'s `remediationInFlight` latch prevents concurrent remediation per identity — no infinite-fast-retry.
- The framework offers no per-attempt success or failure callback. User code that needs to react to reality observes reality, through `StateProvider` + `@Environment` + `.onChange(of:)`.

## Why this is better

The old design violated the framework's own principle from `CONSTITUTION.md`: *Declare what, not when.* `.retry(3, delay: .seconds(10))` is a "when" — three attempts, ten seconds apart. The right knob already existed: `.loopInterval(_:)` controls the cadence of the natural retry.

It also collapsed two competing answers to "how many times will this try?" into one. Previously a `.retry(3)` modifier would do four attempts inside one mount call, then the drift loop would still keep trying forever afterward — the explicit counter never actually bounded anything. Removing it makes the contract honest: the framework converges, period.

## What's next — `.onFail` follow-up

`.onFail` is coming back in a follow-up PR, but with semantics that match the new model: **fires on every loop round where mount throws.** Each convergence attempt is independent; each failure is observable.

```swift
Brew("wget")
    .onFail { error in log(error) }
```

This is per-attempt observability for user code — a logging/MDM-reporting hook, deliberately distinct from telemetry. If the system keeps failing, the handler keeps firing. Consumers who want once-only behavior gate with `@State`.

## Files touched

- `Sources/Astrolabe/Modifiers/RetryModifier.swift` — deleted
- `Sources/Astrolabe/Modifiers/OnFailModifier.swift` — deleted
- `Sources/Astrolabe/Engine/Reconciler.swift` — collapsed to single-attempt void dispatch
- `Sources/Astrolabe/Engine/TaskQueue.swift` — `onComplete` loses its `Bool`
- `Sources/Astrolabe/Engine/LifecycleEngine.swift` — `onComplete` closure shape updated
- `Sources/Astrolabe/Engine/ReconcilableNode.swift` — doc comment for `loop()` updated
- `Sources/Astrolabe/Tree/TreeNode.swift` — `NodeModifier.retry` removed
- `Sources/Astrolabe/Tree/ModifierStore.swift` — `retry`/`onFail` fields and setters removed
- `Sources/Astrolabe/Tree/TreeBuilder.swift` — `RetryModifier`/`OnFailModifier` blocks removed
- `Tests/AstrolabeTests/AstrolabeTests.swift` — retry/onFail attachment tests removed; `anchorWithModifiers` uses `.priority(42)`
- `Tests/AstrolabeTests/ReconcilerTelemetryTests.swift` — retry/onFail tests removed; added `mountThrowingDoesNotEscapeReconciler`
- `Examples/GroupModifiers/GroupModifiers.swift` — switched to `.loopInterval(.seconds(30))`
- `README.md`, `CONSTITUTION.md` — rewritten around the new model
