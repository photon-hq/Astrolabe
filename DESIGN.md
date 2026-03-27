# Astrolabe Design

Astrolabe is a declarative macOS configuration library inspired by SwiftUI. It runs as a long-running daemon — typically installed via a Jamf PreStage enrollment package — and executes setup steps sequentially through device lifecycle phases.

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
            PackageInstaller(.gitHub("org/app", asset: .regex(".*arm64.*\\.pkg")))
            Dialog("Welcome", message: "Your Mac is ready.") {
                Button("Get Started") {
                    print("Setup complete!")
                }
            }
        }
    }
}
```

### Private Repos

Use the environment to pass a GitHub token — it propagates to all children:

```swift
Group {
    PackageInstaller(.gitHub("private/repo1"))
    PackageInstaller(.gitHub("private/repo2"))
}
.environment(\.gitHubToken, ProcessInfo.processInfo.environment["GITHUB_TOKEN"])
```

### Composable Configurations

`Astrolabe` conforms to `Setup`, so configurations can be nested as reusable modules:

```swift
struct DevTools: Astrolabe {
    var body: some Setup {
        PackageInstaller(.gitHub("nicklockwood/SwiftFormat"))
        PackageInstaller(.gitHub("nicklockwood/SwiftLint"))
    }
}

@main
struct MySetup: Astrolabe {
    var body: some Setup {
        EnrollmentComplete {
            DevTools()
        }
    }
}
```

Only the top-level type uses `@main`. Nested ones are reusable setup modules.

## Architecture

### SwiftUI Mapping

| SwiftUI | Astrolabe | Role |
|---------|-----------|------|
| `App` | `Astrolabe` | Entry point protocol |
| `View` | `Setup` | Core step abstraction |
| `@ViewBuilder` | `@SetupBuilder` | Result builder DSL |
| `Group` | `Group` | Step grouping |
| `EnvironmentKey` | `EnvironmentKey` | Custom config keys |
| `.environment()` | `.environment()` | Config propagation |

### `Setup` Protocol

The fundamental building block. Every step, trigger, and combinator conforms to it.

```swift
public protocol Setup: Sendable {
    func execute() async throws
}
```

All steps run sequentially — a step only starts after the previous one finishes. This is by design: dialogs block until dismissed, packages install one at a time, lifecycle triggers wait until their condition is met.

### `Astrolabe` Protocol

The entry point. Conforms to `Setup` so it can be nested.

- `@SetupBuilder var body: Body` — declarative step composition
- `init()` — required for the default `main()` to instantiate
- `execute()` — runs `body.execute()`, enabling nesting
- `static func main() async throws` — entry point for `@main`, requires root (UID 0) or throws `AstrolabeError.notRunningAsRoot`

### `@SetupBuilder` Result Builder

Enables declarative syntax inside `body`. Built with Swift parameter packs (`each S: Setup`) — no limit on the number of steps. Supports:

- Sequential composition — multiple steps in a block
- `if/else` — conditional steps
- `if` without else — optional steps
- Empty body

### Environment

SwiftUI-style environment for passing config down the step tree. Uses `TaskLocal` for implicit propagation — no changes to the `Setup` protocol needed.

- **`EnvironmentKey`** — protocol defining a key + default value
- **`EnvironmentValues`** — key-value storage, read via `EnvironmentValues.current`
- **`.environment(\.key, value)`** — modifier on any `Setup` step
- Values propagate to children, don't leak to siblings
- Nested `.environment()` overrides outer values

**Built-in keys:**

- `gitHubToken` — used by `GitHubPackage` to add `Authorization: Bearer` header for private repos
- `allowUntrusted` — used by `GitHubPackage` to pass `-allowUntrusted` to `installer` for unsigned packages

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

### `Group`

Groups steps for applying shared modifiers:

```swift
Group {
    PackageInstaller(.gitHub("repo1"))
    PackageInstaller(.gitHub("repo2"))
}
.environment(\.gitHubToken, token)
```

### Error Resilience

Step failures are caught and logged — they never crash the daemon. `SetupSequence` wraps each step in `do/catch`, prints the error, and continues to the next step.

## Lifecycle Triggers

Lifecycle triggers wait for a system condition, then run their child steps. Both accept `@SetupBuilder` closures.

### `EnrollmentComplete { }`

Polls `profiles status -type enrollment` every 5 seconds until MDM enrollment is confirmed.

```swift
EnrollmentComplete {
    PackageInstaller(.gitHub("org/cli-tools"))
}
```

### `UserLogin { }`

Uses `SCDynamicStoreCopyConsoleUser` (native Apple API) to detect when a user logs in. Supports filtering by user:

```swift
UserLogin {                              // any user (default)
    Dialog("Welcome") { Button("OK") }
}

UserLogin(user: .name("admin")) {        // specific username
    // admin-only setup
}

UserLogin(user: .uid(501)) {             // specific UID
    // UID-specific setup
}
```

## Steps

### `Dialog`

Displays a macOS dialog via AppleScript. Buttons support action closures.

```swift
Dialog("Welcome", message: "Ready to configure your Mac?") {
    Button("Continue") {
        print("Continuing...")
    }
    Button("Cancel") {
        exit(1)
    }
}
```

- `@ButtonBuilder` closure for unlimited buttons with conditional support
- Executes via `osascript`; parses `button returned:` to run the matching button's action
- Throws `DialogError.cancelled` if dismissed

### `PackageInstaller`

Installs a package from a provider. Generic over `PackageProvider`.

```swift
PackageInstaller(.gitHub("owner/repo"))
PackageInstaller(.gitHub("owner/repo", version: .tag("v1.0.0")))
PackageInstaller(.gitHub("owner/repo", asset: .filename("MyApp-arm64.pkg")))
PackageInstaller(.gitHub("owner/repo", asset: .regex(".*arm64.*\\.pkg")))
```

### Unsigned Packages

Use `.allowUntrusted()` to install packages that aren't signed. Like `.font()` in SwiftUI, the modifier is defined on `Setup` and propagates via the environment — only `PackageInstaller` providers read it:

```swift
PackageInstaller(.gitHub("owner/unsigned-tool"))
    .allowUntrusted()
```

Apply to a group:

```swift
Group {
    PackageInstaller(.gitHub("owner/unsigned1"))
    PackageInstaller(.gitHub("owner/unsigned2"))
}
.allowUntrusted()
```

### `CatalogPackage` Provider

Installs well-known macOS packages with predefined recipes:

```swift
PackageInstaller(.catalog(.homebrew))
PackageInstaller(.catalog(.commandLineTools))
```

| Item | Mechanism |
|------|-----------|
| `.homebrew` | Installs CLT first, then Homebrew `.pkg` from `Homebrew/brew` GitHub Releases |
| `.commandLineTools` | Xcode CLT via `softwareupdate --agree-to-license` (idempotent — skips if already installed) |

### `PackageProvider` Protocol

Extensible protocol for custom package sources:

```swift
public protocol PackageProvider: Sendable {
    func install() async throws
}
```

Dot syntax (`.gitHub(...)`) via constrained extensions. Custom providers:

```swift
struct MyProvider: PackageProvider {
    func install() async throws { ... }
}
PackageInstaller(MyProvider())
```

### `GitHubPackage` Provider

Downloads a `.pkg` from GitHub Releases and installs with `/usr/sbin/installer`.

| Parameter | Options | Default |
|-----------|---------|---------|
| `version` | `.latest`, `.tag("v1.0")` | `.latest` |
| `asset` | `.pkg`, `.filename("name.pkg")`, `.regex("pattern")` | `.pkg` |

- Reads `gitHubToken` from environment for private repo authentication
- Reads `allowUntrusted` from environment to pass `-allowUntrusted` to `installer`
- Fetches release → finds matching asset → downloads → installs via `installer -pkg`

## Deployment

Astrolabe runs as a **long-running daemon** — on first run, it self-registers a LaunchDaemon (`codes.photon.astrolabe`) with `KeepAlive: true` so launchd keeps it running permanently. This happens automatically in `main()`:

1. Root check — throws `AstrolabeError.notRunningAsRoot` if not UID 0
2. Writes `/Library/LaunchDaemons/codes.photon.astrolabe.plist` if not already present
3. Bootstraps via `launchctl bootstrap system`
4. `EnrollmentComplete { }` polls until MDM enrollment finishes
5. Steps within `EnrollmentComplete` execute sequentially
6. `UserLogin { }` polls via `SCDynamicStoreCopyConsoleUser` until a user logs in
7. Steps within `UserLogin` execute (dialogs, user-context packages, etc.)

The daemon acts as a persistent agent — if the process exits or crashes, launchd restarts it automatically.

## File Structure

```
Sources/Astrolabe/
├── Astrolabe.swift              Entry point protocol (conforms to Setup)
├── Setup.swift                  Core Setup protocol
├── SetupBuilder.swift           @resultBuilder (parameter packs)
├── Environment/
│   ├── EnvironmentKey.swift     Key protocol with default value
│   ├── EnvironmentValues.swift  TaskLocal-backed storage
│   ├── EnvironmentModifier.swift .environment() modifier
│   ├── GitHubTokenKey.swift     Built-in GitHub token key
│   └── AllowUntrustedKey.swift  Built-in key + .allowUntrusted() modifier
├── SetupTypes/
│   ├── SetupSequence.swift      Sequential composition (error resilient)
│   ├── ConditionalSetup.swift   if/else support
│   ├── OptionalSetup.swift      if-without-else support
│   ├── EmptySetup.swift         No-op step
│   └── Group.swift              Step grouping + modifier target
└── Steps/
    ├── EnrollmentComplete.swift Polls for MDM enrollment
    ├── UserLogin.swift          Polls for user login (.all/.name/.uid)
    ├── Dialog/
    │   ├── Dialog.swift         AppleScript dialog
    │   ├── Button.swift         Button with action closure
    │   └── ButtonBuilder.swift  @resultBuilder for buttons
    └── PackageInstaller/
        ├── PackageInstaller.swift   Generic installer step
        └── Providers/
            ├── PackageProvider.swift Extensible provider protocol
            ├── GitHubPackage.swift   GitHub Releases provider
            └── CatalogPackage.swift  Predefined packages (Homebrew, CLT)
```

## Platform

- macOS 14+ (required for parameter packs)
- Swift 6.2+
- All types are `Sendable` for strict concurrency
- Execution is `async throws` throughout
