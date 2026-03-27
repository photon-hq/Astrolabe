# Astrolabe Design

Astrolabe is a declarative macOS configuration library. Developers use it in CLI executables to define their machine setup as a sequence of steps, using a SwiftUI-inspired syntax.

## Consumer Usage

```swift
import Astrolabe

@main
struct MySetup: Astrolabe {
    var body: some Setup {
        Wait.userLogin
        Package.install
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

### Step Namespaces

Simple steps are exposed via caseless enum namespaces with static properties:

```swift
public enum Wait {
    public static var userLogin: WaitForUserLogin { ... }
}

public enum Package {
    public static var install: PackageInstall { ... }
}
```

Each property returns a concrete struct conforming to `Setup`.

### Parameterized Steps

Steps that take configuration use struct initializers directly, with result builders for nested content where appropriate.

#### `Dialog`

Displays a macOS dialog via AppleScript. Uses `@ButtonBuilder` to collect buttons declaratively.

```swift
Dialog("Welcome", message: "Ready to configure your Mac?") {
    Button("Continue")
    Button("Not Now")
    Button("Cancel")
}
```

- Title and message are string parameters
- Buttons are declared in a trailing `@ButtonBuilder` closure (unlimited count)
- `@ButtonBuilder` supports conditionals (`if/else`, `if`)
- Executes via `osascript`; throws `DialogError.cancelled` if the user dismisses

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
├── Components/
│   ├── Button.swift             Button type
│   └── ButtonBuilder.swift      @resultBuilder for buttons
└── Steps/
    ├── Dialog.swift             AppleScript dialog step
    ├── Wait.swift               Wait namespace
    └── Package.swift            Package namespace
```

## Platform

- macOS 14+ (required for parameter packs)
- Swift 6.2+
- All types are `Sendable` for strict concurrency
- Execution is `async throws` throughout
