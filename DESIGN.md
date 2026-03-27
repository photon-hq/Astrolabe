# Astrolabe Design

Astrolabe is a declarative macOS configuration library. Developers use it in CLI executables to define their machine setup as a sequence of steps, using a SwiftUI-inspired syntax.

## Consumer Usage

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    var body: some Setup {
        Wait.userLogin
        PackageInstaller(.gitHub("owner/repo", version: .latest))
        PackageInstaller(.jamf(name: "Google Chrome"))
    }
}
```

## Architecture

The design mirrors SwiftUI's component model:

| SwiftUI         | Astrolabe        | Role                          |
|-----------------|------------------|-------------------------------|
| `App`           | `Astrolabe`      | Entry point protocol          |
| `View` / `Scene`| `Setup`          | Core step abstraction         |
| `@ViewBuilder`  | `@SetupBuilder`  | Result builder for DSL syntax |
| `WindowGroup`   | `Wait.userLogin` | Concrete step                 |

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

### Steps

#### Simple Steps

Exposed via caseless enum namespaces with static properties:

```swift
public enum Wait {
    public static var userLogin: WaitForUserLogin { ... }
}
```

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

Dot syntax (`.gitHub(...)`, `.jamf(...)`) is enabled via constrained extensions on `PackageProvider`:

```swift
extension PackageProvider where Self == GitHubPackage {
    public static func gitHub(_ repo: String, version: ...) -> GitHubPackage
}
```

**Built-in providers:**

| Provider | Identifier | Mechanism |
|----------|-----------|-----------|
| `GitHubPackage` | `"owner/repo"` + version (`.latest` / `.tag`) | GitHub Releases API → download `.pkg` → `installer` |
| `JamfPackage` | name, id, or trigger | `jamf policy` CLI |

**Custom providers:** Conform to `PackageProvider` and pass to `PackageInstaller()`:

```swift
struct MyProvider: PackageProvider {
    func install() async throws { ... }
}

PackageInstaller(MyProvider())
```

## File Structure

```
Sources/Astrolabe/
├── Astrolabe.swift              Entry point protocol
├── Setup.swift                  Core Setup protocol
├── SetupBuilder.swift           @resultBuilder
├── SetupTypes/
│   ├── SetupSequence.swift      Sequential composition (parameter packs)
│   ├── ConditionalSetup.swift   if/else support
│   ├── OptionalSetup.swift      if-without-else support
│   └── EmptySetup.swift         No-op step
└── Steps/
    ├── Wait.swift               Wait namespace
    ├── Dialog/
    │   ├── Dialog.swift         AppleScript dialog step
    │   ├── Button.swift         Button type with action closure
    │   └── ButtonBuilder.swift  @resultBuilder for buttons
    └── PackageInstaller/
        ├── PackageInstaller.swift   Generic package installer step
        └── Providers/
            ├── PackageProvider.swift Provider protocol
            ├── GitHubPackage.swift   GitHub Releases provider
            └── JamfPackage.swift     Jamf Pro provider
```

## Platform

- macOS 14+ (required for parameter packs)
- Swift 6.2+
- All types are `Sendable` for strict concurrency
- Execution is `async throws` throughout
