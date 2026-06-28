# AGENTS.md

## Cursor Cloud specific instructions

### What this is
Astrolabe is a **macOS-only** Swift Package (SwiftPM, `swift-tools-version: 6.2`,
`platforms: [.macOS(.v15)]`). It is a declarative macOS configuration framework that
runs as a LaunchDaemon and reconciles system state (Homebrew, launchd, Jamf, system
settings). It ships two libraries (`Astrolabe`, `AstrolabeUtils`) plus example
executables under `Examples/`. There are no web servers, databases, or other
long-running services to start. See `README.md` for the full surface and run/CLI
commands, and `CONSTITUTION.md` for design invariants.

### Hard platform constraint (important)
The Cursor Cloud VM is **Linux**, but this package can only be **built, tested, and
run on macOS 15+**. The package's own targets import macOS-only modules with no
`#if os(...)` guards — e.g. `import Darwin` (in `AstrolabeUtils/StorageClient.swift`,
`Astrolabe.swift`, `LifecycleEngine.swift`, `RunEngine.swift`, `DaemonManager.swift`,
`UpdateLoop.swift`, `UpdaterDaemonManager.swift`) and `import SystemConfiguration`
(in `BrewHelper.swift`, `HostnameSetting.swift`), plus runtime use of `launchd`,
`pkgutil`, `installer`, `scutil`, `launchctl`, and Homebrew.

Consequence on the Linux VM:
- `swift package resolve` and `swift package describe` **work**.
- `swift build` compiles the entire third-party dependency graph (NIO, gRPC,
  swift-crypto/BoringSSL, OpenTelemetry, ArgumentParser, etc.) successfully, then
  **fails** on the first Astrolabe target with `error: no such module 'Darwin'`.
- `swift build` / `swift test` / running the examples therefore **cannot succeed on
  Linux**. Do this work on a macOS 15+ host (`swift build`, `swift test`,
  `sudo .build/debug/<Example>`). Do not "fix" this by adding platform guards unless
  that is the explicit task — it is an environment limitation, not a repo bug.

### Toolchain on the Linux VM
- Swift **6.2.4** is installed via `swiftly` (matches `swift-tools-version: 6.2`).
  It is on `PATH` for login shells. In a non-login/non-interactive context, call it
  by absolute path `"$HOME/.local/share/swiftly/bin/swift"` or source
  `"$HOME/.local/share/swiftly/env.sh"` first.
- C++ dependencies (swift-nio-ssl's bundled BoringSSL) require C++ stdlib headers.
  The bundled clang selects the **gcc-14** toolchain, so `libstdc++-14-dev` must be
  present (not just `libstdc++-13-dev`); otherwise the C++ deps fail with
  `'memory' file not found`. This is already installed in the VM snapshot.
