# Astrolabe

A declarative macOS configuration framework. Describe the desired state of a machine -- packages, services, system settings -- and Astrolabe continuously converges reality to match.

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

            LaunchAgent("com.example.myagent", program: "/usr/local/bin/myagent")
                .runAtLoad()
                .keepAlive()
                .activate()
        }
    }
}
```

## How it works

Astrolabe runs as a persistent LaunchDaemon. On each tick:

1. **Read state** -- snapshot environment values (enrollment status, console user, etc.)
2. **Build tree** -- evaluate `body` with current state to produce a declaration tree
3. **Diff** -- compare current tree leaves against previous leaves using content-based identity
4. **Reconcile** -- enqueue mount/unmount tasks for additions and removals

Every node implements a single `ReconcilableNode` protocol with `mount()` and `unmount()` (both default to no-ops). Nodes override only what they need -- Sys and Jamf override `mount()`, Brew/Pkg/LaunchDaemon/LaunchAgent override `unmount()` and attach a bootstrap task that polls and self-installs.

The tick is fully synchronous. All async work (downloads, installs) runs in detached tasks. State changes from providers or `@State` mutations trigger the next tick automatically.

```
State Sources -> StateNotifier -> tick() -> Tree Diff -> TaskQueue -> Reconciler
```

## Declarations

| Type | Lifecycle | Purpose |
|------|-----------|---------|
| `Brew("wget")` | unmount + bootstrap task | Homebrew formula or cask |
| `Pkg(.catalog(.homebrew))` | unmount + bootstrap task | Non-Homebrew packages (catalog, GitHub `.pkg`, custom) |
| `Sys(.hostname("name"))` | mount only | System configuration |
| `Jamf(.computerName("name"))` | mount only | Jamf configuration |
| `LaunchDaemon(label, program:)` | unmount + bootstrap task | System-level launchd service |
| `LaunchAgent(label, program:)` | unmount + bootstrap task | Per-user launchd service |
| `Anchor()` | no-op | Modifier-only attachment point |

```swift
// Homebrew
Brew("wget")
Brew("firefox", type: .cask)

// Packages
Pkg(.catalog(.commandLineTools))
Pkg(.gitHub("org/tool", version: .tag("v2.0")))

// Launchd services
LaunchDaemon("com.example.daemon", program: "/usr/local/bin/daemon")
    .keepAlive()
    .standardOutPath("/var/log/daemon.log")
    .activate()

LaunchAgent("com.example.agent", program: "/usr/local/bin/agent")
    .runAtLoad()
    .environmentVariables(["KEY": "value"])
    .activate()  // bootstraps for every logged-in user

// System config
Sys(.hostname("dev-mac"))
```

Composable -- group related declarations into reusable components:

```swift
struct DevTools: Setup {
    var body: some Setup {
        Brew("swiftformat")
        Brew("swiftlint")
        Brew("git-lfs")
    }
}
```

## State

### `@State` -- local ephemeral state

In-memory only. Resets on daemon restart. Mutations trigger re-evaluation.

```swift
@State var showWelcome = true
```

### `@Storage` -- persistent local state

Like `@State`, but persisted to disk -- survives daemon restart. Accepts any `Codable` value.

```swift
@Storage("hasCompletedOnboarding") var hasCompletedOnboarding = false
@Storage("preferredBrowser") var preferredBrowser: String = "firefox"
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
    .preInstall { await validate() }    // pre-install hook
    .postInstall { await configure() }  // post-install hook

Pkg(.gitHub("org/tool"))
    .allowUntrusted()                   // unsigned packages
    .preUninstall { await backup() }    // pre-uninstall hook

Group {
    Pkg(.gitHub("private/repo1"))
    Pkg(.gitHub("private/repo2"))
}
.environment(\.gitHubToken, token)      // config propagation

Group {
    LaunchAgent("com.example.a", program: "/usr/local/bin/a")
    LaunchAgent("com.example.b", program: "/usr/local/bin/b")
}
.runAtLoad()                            // launchd plist config
.keepAlive()                            // propagates through Group
.activate()                             // immediate bootstrapping

Brew("iterm2", type: .cask)
    .dialog("Welcome!", message: "Mac is ready.",
            isPresented: $showWelcome) {
        Button("Get Started")
    }

Pkg(.catalog(.homebrew))
    .task { await setupBrewTaps() }     // lifecycle-bound async work

Anchor()
    .onChange(of: isEnrolled) { old, new in
        print("Enrollment changed: \(old) → \(new)")
    }
```

## Lifecycle

```swift
@main
struct MySetup: Astrolabe {
    init() {
        Self.pollInterval = .seconds(10)
        Self.daemonMode = true  // default — installs and exits, launchd takes over
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

### Daemon mode (`daemonMode = true`, default)

The first `sudo` invocation installs a LaunchDaemon, bootstraps it, and exits. From then on, launchd manages the process -- auto-start on boot, restart on crash.

Re-running the binary detects whether the daemon is already running and exits as a no-op. If the binary path changed (rebuild, move), the plist is updated and the daemon re-bootstrapped automatically.

To force-overwrite the daemon plist (e.g. after a config change):

```bash
sudo .build/debug/MySetup install-daemon --force
```

To remove the daemon:

```bash
sudo .build/debug/MySetup uninstall-daemon
```

### Inline mode (`daemonMode = false`)

The engine runs directly in the current process. Any previously installed daemon is removed. Useful for development and examples.

Startup sequence: root check -> daemon mode resolution -> load PayloadStore -> load StorageStore -> `onStart()` -> seed providers -> first tick -> poll loop.

## Requirements

- macOS 14+
- Swift 6.2+

## AstrolabeUtils

Separate lightweight package for accessing Astrolabe's persistent storage from other processes on the Mac. No dependency on the full framework.

```swift
import AstrolabeUtils

let client = StorageClient()
let browser: String? = client.read("preferredBrowser")
try client.write("preferredBrowser", value: "safari")
```

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

For other processes that only need storage access:

```swift
targets: [
    .executableTarget(
        name: "MyTool",
        dependencies: [
            .product(name: "AstrolabeUtils", package: "Astrolabe"),
        ]
    ),
]
```

## Running

Build and run with root privileges (required for package installation and LaunchDaemon registration):

```bash
swift build
sudo .build/debug/MySetup
```

By default (`daemonMode = true`), the first run installs a LaunchDaemon (`codes.photon.astrolabe`) with `KeepAlive` and `RunAtLoad`, then exits. launchd manages the process from then on. Subsequent runs detect the running daemon and exit immediately.

Astrolabe exposes a subcommand surface built on [swift-argument-parser](https://github.com/apple/swift-argument-parser):

```bash
sudo .build/debug/MySetup                      # default: install daemon or run engine
sudo .build/debug/MySetup install-daemon --force
sudo .build/debug/MySetup uninstall-daemon
sudo .build/debug/MySetup --help               # lists every subcommand, including yours
```

## Custom Commands

Consumer apps can register their own subcommands. When a registered command runs, Astrolabe takes **no framework action** -- no daemon install, no engine tick, no `init()` on your `Astrolabe` type, no `onStart`/`onExit`. Your command gets the process to itself.

Declare a command as an `AsyncParsableCommand` and add it to `commands`:

```swift
import Astrolabe
import ArgumentParser

@main
struct MySetup: Astrolabe {
    var body: some Setup {
        Pkg(.catalog(.homebrew))
        Brew("wget")
    }

    static var commands: [any AsyncParsableCommand.Type] {
        [Status.self, Logout.self]
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show what Astrolabe has installed."
    )

    func run() async throws {
        for (identity, record) in AstrolabeState.payloads() {
            print("\(identity): \(record)")
        }
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout")

    @Flag(name: .shortAndLong) var force = false

    func run() async throws {
        // app-specific logic; Astrolabe does nothing on its own here
    }
}
```

Invoke:

```bash
sudo .build/debug/MySetup status
sudo .build/debug/MySetup logout --force
sudo .build/debug/MySetup logout --help  # per-subcommand help, auto-generated
```

`@Argument`, `@Option`, `@Flag`, validation, usage text, and `--help` come from swift-argument-parser — the framework's own `install-daemon --force` flag is declared the same way.

`AstrolabeState` exposes read-only accessors safe to call from a command (no engine required):

```swift
AstrolabeState.payloads()           // [(NodeIdentity, PayloadRecord)]
AstrolabeState.identities()         // Set<NodeIdentity>
AstrolabeState.storage("key", as: String.self)  // T?  — reads @Storage values
```

## Examples

See the [`Examples/`](Examples/) directory:

- **BasicSetup** -- minimal configuration installing a few Homebrew packages
- **ConditionalSetup** -- declarations gated on environment values like enrollment status
- **GroupModifiers** -- applying retry policies and modifiers to groups of declarations

## Design

See [CONSTITUTION.md](CONSTITUTION.md) for the fundamental design decisions and invariants.
