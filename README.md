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

Every node implements a single `ReconcilableNode` protocol with `mount()`, `loop()`, and `unmount()` (all default to no-ops / `.healthy`). Nodes override only what they need -- `mount()` performs the system change, `loop()` periodically verifies the change still holds and returns `.drifted` to trigger a re-mount, and `unmount()` reverses it.

The tick is fully synchronous. All async work (downloads, installs) runs in detached tasks. State changes from providers or `@State` mutations trigger the next tick automatically. Per-node drift-check loops run on their own cadence (default 15s, configurable with `.loopInterval(_:)`) and re-mount through the same retry / `onFail` machinery as the initial mount.

```
State Sources -> StateNotifier -> tick() -> Tree Diff -> TaskQueue -> Reconciler
                                                                ^
                                             LoopSupervisor ----+ (drift -> re-mount)
```

## Declarations

| Type | Lifecycle | Purpose |
|------|-----------|---------|
| `Brew("wget")` | mount + loop + unmount | Homebrew formula or cask |
| `Pkg(.catalog(.homebrew))` | mount + loop + unmount | Non-Homebrew packages (catalog, GitHub `.pkg`, custom) |
| `Sys(.hostname("name"))` | mount + loop | System configuration |
| `Jamf(.computerName("name"))` | mount + loop | Jamf configuration |
| `LaunchDaemon(label, program:)` | mount + loop + unmount | System-level launchd service |
| `LaunchAgent(label, program:)` | mount + loop + unmount | Per-user launchd service |
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

## Telemetry (optional)

Astrolabe does not send telemetry by default. Telemetry can be enabled explicitly with `SignozAstrolabeTelemetry`. Astrolabe telemetry records operational metadata only. Astrolabe telemetry must not record secrets, file contents, full config contents, or raw command output.

### Opt in

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    static let telemetry: AstrolabeTelemetry = SignozAstrolabeTelemetry(
        serviceName: "my-setup",
        endpoint: "ingest.signoz.io:4317",
        environment: "production",
        serviceVersion: "1.0.0",
        headers: ["signoz-ingestion-key": "..."],
        transportSecurity: .tls,
        verbose: true
    )

    var body: some Setup {
        Brew("wget")
    }
}
```

`verbose: true` adds `astrolabe.node.identity` (canonical path, e.g. `n:brew:formula:wget`) to node spans and logs. Default is `false` (hash only). Error messages are never sent to telemetry.

The built-in engine calls `telemetry.shutdown()` after shutdown logging to flush OTLP exports. Custom CLIs that exit without running the engine should call `MySetup.telemetry.shutdown()` before process exit.

### What gets recorded

- A top-level `astrolabe.run` span around the engine's lifetime.
- An `astrolabe.mount` span per mount attempt loop, with `astrolabe.node.type` (e.g. `"BrewInfo"`) and `astrolabe.node.id_hash` (8-char SHA-256 prefix of identity).
- With `verbose: true`, `astrolabe.node.identity` (canonical identity path).
- An `astrolabe.unmount` span per unmount.
- Log events for run start/shutdown, tick, scheduled mounts/unmounts, drift detection, mount/unmount failures, and persistence write failures.
- `recordCounter` exists on the protocol but is a **no-op** in this release (reserved for future metrics).

### What never gets recorded

- Error descriptions / messages — only `String(describing: type(of: error))`.
- By default, node identity paths and package names — only `astrolabe.node.id_hash` (set `verbose: true` to include `astrolabe.node.identity`).
- `displayName`, environment values, `@State`, `@Storage`, raw shell commands or output, full config contents, secrets.

## Modifiers

```swift
Brew("wget")
    .retry(3, delay: .seconds(10))     // retry on failure
    .onFail { error in log(error) }     // error callback
    .preInstall { await validate() }    // pre-install hook
    .postInstall { await configure() }  // post-install hook
    .loopInterval(.seconds(60))         // override drift-check cadence (default 15s)

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

- macOS 15+
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

## Self-Update

Astrolabe ships with a built-in self-updater. Set `static var update` on your
conforming type and `install-daemon` provisions a sibling LaunchDaemon
(`<label>.updater`) that polls the configured source, downloads/verifies the
new `.pkg`, and replaces this binary automatically.

```swift
@main
struct MySetup: Astrolabe {
    // Required: stamp the version on every release. CI should bump this.
    static var version: String { "1.2.3" }

    // Opt-in: minimum config.
    static var update: UpdateConfiguration? {
        UpdateConfiguration(.gitHub("acme/mysetup"))
    }

    var body: some Setup { ... }
}
```

The full surface:

```swift
static var update: UpdateConfiguration? {
    UpdateConfiguration(.gitHub("acme/mysetup", asset: .pkg))
        .interval(.hours(1))                       // default: 1 hour
        .channel(.stable)                          // .stable | .prerelease
        .verify(.codesignTeamID("ABCD123456"))     // default: .pkgSignatureRequired
        .allowDowngrade(false)                     // default: false
        .githubToken(token)                        // injected into updater plist
        .preUpdate  { from, to in try await backup() }
        .postUpdate { v in await reportToMDM(v) }
        .onFail     { error in print(error) }
}
```

### Verification options

- `.none` -- skip verification. Development only.
- `.pkgSignatureRequired` *(default)* -- pkg must pass `pkgutil --check-signature`.
- `.codesignTeamID("ABCD123456")` -- pkg must be signed AND the Apple Team ID
  inside the certificate must match exactly. Strongest binding.

### What happens on update

1. Updater fetches the latest release from the source.
2. Compares against `version` parsed as SemVer (refuses downgrades by default).
3. Downloads the `.pkg` to a temp directory, verifies signature.
4. Runs your `preUpdate` hook (errors abort).
5. Runs `/usr/sbin/installer -pkg ... -target /` -- transactional.
6. Runs your `postUpdate` hook.
7. `launchctl kickstart -k system/<main-label>` restarts the main daemon.
8. Updater `execv`s itself so it also runs the new binary.

### CLI

```
sudo mysetup update-status     # show last check / last update / last error
sudo mysetup uninstall-daemon  # removes both daemons
```

### Pinning a tag

```swift
UpdateConfiguration(.gitHub("acme/mysetup", version: .tag("v1.2.3")))
```

Pinned tags mean "install this exact version once if newer, then no-op."
Useful for staged rollouts and emergency rollback channels.

## Examples

See the [`Examples/`](Examples/) directory:

- **BasicSetup** -- minimal configuration installing a few Homebrew packages
- **ConditionalSetup** -- declarations gated on environment values like enrollment status
- **GroupModifiers** -- applying retry policies and modifiers to groups of declarations
- **SelfUpdating** -- auto-update from a GitHub release source

## Design

See [CONSTITUTION.md](CONSTITUTION.md) for the fundamental design decisions and invariants.
