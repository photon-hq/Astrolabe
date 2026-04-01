# Astrolabe

A declarative macOS configuration framework. Describe the desired state of a machine -- packages, conditions, environment -- and Astrolabe continuously converges reality to match.

Inspired by SwiftUI's programming model: you write a `body` that declares *what should exist*, and the framework figures out *when and how* to make it so.

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    @Environment(\.isEnrolled) var isEnrolled

    var body: some Setup {
        Pkg(.catalog(.commandLineTools))
        Pkg(.catalog(.homebrew))
        Brew("wget")

        if isEnrolled {
            Brew("git-lfs")
            Brew("firefox", type: .cask)
            Pkg(.gitHub("org/internal-tool"))
                .retry(3)
                .onFail { error in reportToMDM(error) }
        }
    }
}
```

## How it works

Astrolabe runs as a persistent LaunchDaemon. On each tick:

1. **Read state** -- snapshot environment values (enrollment status, console user, etc.)
2. **Build tree** -- evaluate `body` with current state to produce a declaration tree
3. **Diff** -- compare current tree leaves against previous leaves
4. **Reconcile** -- enqueue install tasks for additions, uninstall tasks for removals

The tick is fully synchronous. All async work (downloads, installs) runs in detached tasks. State changes from providers or `@State` mutations trigger the next tick automatically.

```
State Sources → StateNotifier/StateGraph → tick() → Tree Diff → TaskQueue → Reconciler → PayloadStore
```

## Declarations

### Brew

Homebrew formula or cask:

```swift
Brew("wget")                      // formula
Brew("firefox", type: .cask)     // cask
```

### Pkg

Packages from other sources:

```swift
Pkg(.catalog(.homebrew))          // Homebrew itself
Pkg(.catalog(.commandLineTools))  // Xcode Command Line Tools
Pkg(.gitHub("org/tool"))          // GitHub release .pkg
Pkg(.gitHub("org/tool", version: .tag("v2.0")))
Pkg(.gitHub("org/tool", asset: .regex(".*arm64.*\\.pkg")))
```

### Composable setups

Group related declarations into reusable components:

```swift
struct DevTools: Setup {
    var body: some Setup {
        Brew("swiftformat")
        Brew("swiftlint")
        Brew("git-lfs")
    }
}

// Use it like any other declaration
var body: some Setup {
    DevTools()
}
```

## State

### `@State` -- local ephemeral state

In-memory only. Resets on daemon restart. Mutations trigger re-evaluation.

```swift
@State var showWelcome = true
```

### `@Environment` -- framework-managed state

Read-only values derived from the system by polling providers:

```swift
@Environment(\.isEnrolled) var isEnrolled
```

A built-in provider checks MDM enrollment status. Custom providers conform to `StateProvider`.

## Modifiers

```swift
Brew("wget")
    .retry(3, delay: .seconds(10))     // retry on failure
    .onFail { error in log(error) }     // error callback

Pkg(.gitHub("org/tool"))
    .allowUntrusted()                   // unsigned packages

Group {
    Pkg(.gitHub("private/repo1"))
    Pkg(.gitHub("private/repo2"))
}
.environment(\.gitHubToken, token)      // config propagation

Brew("iterm2", type: .cask)
    .dialog("Welcome!", message: "Mac is ready.",
            isPresented: $showWelcome) {
        Button("Get Started")
    }

Pkg(.catalog(.homebrew))
    .task { await setupBrewTaps() }     // lifecycle-bound async work
```

## Lifecycle

```swift
@main
struct MySetup: Astrolabe {
    init() {
        Self.pollInterval = .seconds(10)
    }

    func onStart() async throws {
        // Runs after persistence loads, before first tick.
        // Fetch config, authenticate, pre-clean state.
    }

    func onExit() {
        // Runs on SIGTERM/SIGINT. Keep it fast.
    }

    var body: some Setup { ... }
}
```

Startup sequence: root check -> daemon install -> load PayloadStore -> `onStart()` -> seed providers -> first tick -> poll loop.

## Requirements

- macOS 14+
- Swift 6.2+

## Installation

Add Astrolabe as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/photonlines/Astrolabe.git", from: "0.1.0"),
],
targets: [
    .executableTarget(
        name: "MySetup",
        dependencies: ["Astrolabe"]
    ),
]
```

## Running

Build and run with root privileges (required for package installation and LaunchDaemon registration):

```bash
swift build
sudo .build/debug/MySetup
```

On first run, Astrolabe installs itself as a LaunchDaemon (`codes.photon.astrolabe`) with `KeepAlive` and `RunAtLoad` enabled. After that, launchd keeps it running.

## Examples

See the [`Examples/`](Examples/) directory:

- **BasicSetup** -- minimal configuration installing a few Homebrew packages
- **ConditionalSetup** -- declarations gated on environment values like enrollment status
- **GroupModifiers** -- applying retry policies and modifiers to groups of declarations

## Design

See [DESIGN.md](DESIGN.md) for the full architecture, including the SwiftUI mapping, state system, concurrency model, and reconciliation strategy.
