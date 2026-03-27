# Astrolabe Design

Astrolabe is a declarative macOS configuration library. It runs as a long-running daemon, typically installed via a Jamf PreStage enrollment package. Developers define their machine setup as a sequence of steps using a SwiftUI-inspired syntax.

## Consumer Usage

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    var body: some Setup {
        EnrollmentComplete {
            PackageInstaller(.gitHub("org/cli-tools"))
        }
        UserLogin {
            PackageInstaller(.gitHub("owner/repo"))
            Dialog("Welcome") { Button("OK") }
        }
    }
}
```

## Architecture

The design mirrors SwiftUI's component model:

| SwiftUI         | Astrolabe              | Role                          |
|-----------------|------------------------|-------------------------------|
| `App`           | `Astrolabe`            | Entry point protocol          |
| `View` / `Scene`| `Setup`                | Core step abstraction         |
| `@ViewBuilder`  | `@SetupBuilder`        | Result builder for DSL syntax |
| `WindowGroup`   | `EnrollmentComplete`   | Lifecycle trigger             |

### `Setup` Protocol

The fundamental building block. Every configuration action conforms to it.

```swift
public protocol Setup: Sendable {
    func execute() async throws
}
```

### `Astrolabe` Protocol

The entry point. Consumers conform with `@main` to get a `static func main() async throws` for free.

- Requires a `@SetupBuilder var body: Body` property
- Requires `init()` so the default `main()` can instantiate it
- `main()` creates an instance and calls `body.execute()`

### `@SetupBuilder` Result Builder

Enables declarative syntax inside `body`. Built with Swift parameter packs (`each S: Setup`) so there is no limit on the number of steps. Supports:

- Sequential composition — multiple steps in a block
- `if/else` — `ConditionalSetup<First, Second>`
- `if` without else — `OptionalSetup<Wrapped>`
- Empty body — `EmptySetup`

### Environment

SwiftUI-style environment system for passing configuration to steps. Uses Swift `TaskLocal` for implicit propagation — no changes to the `Setup` protocol needed.

```swift
Group {
    PackageInstaller(.gitHub("private/repo1"))
    PackageInstaller(.gitHub("private/repo2"))
}
.environment(\.gitHubToken, "ghp_xxx")
```

- **`EnvironmentKey`** protocol — defines a key with a default value
- **`EnvironmentValues`** — key-value storage, accessed via `EnvironmentValues.current`
- **`.environment(\.key, value)`** — modifier on any `Setup` step
- Values propagate to all children but don't leak to siblings
- Built-in key: `gitHubToken` (used by `GitHubPackage` for private repos)

### `Group`

Groups multiple steps. Useful for applying modifiers to a set of steps.

```swift
Group {
    PackageInstaller(.gitHub("repo1"))
    PackageInstaller(.gitHub("repo2"))
}
.environment(\.gitHubToken, token)
```

### Error Resilience

Step failures are caught and logged — they never crash the daemon. `SetupSequence` wraps each step in a `do/catch`, prints the error, and continues to the next step. This is critical since Astrolabe runs as a long-lived daemon.

### Lifecycle Triggers

Lifecycle triggers wait for a system condition, then run their child steps.

#### `EnrollmentComplete { }`

Polls `profiles status -type enrollment` every 5 seconds until MDM enrollment is confirmed, then runs child steps sequentially.

```swift
EnrollmentComplete {
    PackageInstaller(.jamf(trigger: "installCLITools"))
}
```

#### `UserLogin { }`

Polls `/dev/console` ownership until a non-root user is logged in, then runs child steps sequentially.

```swift
UserLogin {
    Dialog("Welcome") { Button("OK") }
}
```

Both accept a `@SetupBuilder` closure, so they compose naturally with all other steps.

### Steps

#### `Dialog`

Displays a macOS dialog via AppleScript. Uses `@ButtonBuilder` to collect buttons declaratively. Buttons support action closures that run when pressed.

```swift
Dialog("Welcome", message: "Ready to configure your Mac?") {
    Button("Continue") {
        print("Continuing setup...")
    }
    Button("Cancel") {
        exit(1)
    }
}
```

- Title and message are string parameters
- Buttons are declared in a trailing `@ButtonBuilder` closure (unlimited count)
- `@ButtonBuilder` supports conditionals (`if/else`, `if`)
- Executes via `osascript`; parses `button returned:` to run the matching button's action
- Throws `DialogError.cancelled` if the user dismisses

#### `PackageInstaller`

Installs a package from a provider. Generic over `PackageProvider`:

```swift
PackageInstaller(.gitHub("owner/repo", version: .latest))
PackageInstaller(.gitHub("owner/repo", version: .tag("v1.0.0")))
PackageInstaller(.jamf(name: "Google Chrome"))
PackageInstaller(.jamf(id: 1265))
PackageInstaller(.jamf(trigger: "installChrome"))
```

### `PackageProvider` Protocol

Extensible protocol for custom package sources. Inspired by SPM's dependency design.

```swift
public protocol PackageProvider: Sendable {
    func install() async throws
}
```

Dot syntax (`.gitHub(...)`) is enabled via constrained extensions on `PackageProvider`.

**Built-in providers:**

| Provider | Identifier | Mechanism |
|----------|-----------|-----------|
| `GitHubPackage` | `"owner/repo"` + version (`.latest` / `.tag`) | GitHub Releases API → download `.pkg` → `installer` |

**Custom providers:** Conform to `PackageProvider` and pass to `PackageInstaller()`:

```swift
struct MyProvider: PackageProvider {
    func install() async throws { ... }
}

PackageInstaller(MyProvider())
```

## Deployment

Astrolabe is designed to run as a **long-running daemon** installed via a Jamf PreStage enrollment package:

1. PreStage .pkg installs the Astrolabe binary + LaunchDaemon plist
2. .pkg postinstall runs `launchctl bootstrap` to start immediately
3. `EnrollmentComplete { }` polls until MDM enrollment finishes
4. `UserLogin { }` polls until a user logs in
5. Steps execute sequentially within each lifecycle phase

## File Structure

```
Sources/Astrolabe/
├── Astrolabe.swift              Entry point protocol
├── Setup.swift                  Core Setup protocol
├── SetupBuilder.swift           @resultBuilder
├── Environment/
│   ├── EnvironmentKey.swift     Key protocol
│   ├── EnvironmentValues.swift  TaskLocal-backed storage
│   ├── EnvironmentModifier.swift .environment() modifier
│   └── GitHubTokenKey.swift     Built-in GitHub token key
├── SetupTypes/
│   ├── SetupSequence.swift      Sequential composition (error resilient)
│   ├── ConditionalSetup.swift   if/else support
│   ├── OptionalSetup.swift      if-without-else support
│   ├── EmptySetup.swift         No-op step
│   └── Group.swift              Step grouping
└── Steps/
    ├── EnrollmentComplete.swift Lifecycle: wait for MDM enrollment
    ├── UserLogin.swift          Lifecycle: wait for user login
    ├── Dialog/
    │   ├── Dialog.swift         AppleScript dialog step
    │   ├── Button.swift         Button type with action closure
    │   └── ButtonBuilder.swift  @resultBuilder for buttons
    └── PackageInstaller/
        ├── PackageInstaller.swift   Generic package installer step
        └── Providers/
            ├── PackageProvider.swift Provider protocol
            └── GitHubPackage.swift   GitHub Releases provider
```

## Platform

- macOS 14+ (required for parameter packs)
- Swift 6.2+
- All types are `Sendable` for strict concurrency
- Execution is `async throws` throughout
