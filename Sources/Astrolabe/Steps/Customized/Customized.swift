/// A step you define inline with your own `mount`, `check`, and `unmount` logic.
///
/// `Customized` is the "build your own step" escape hatch. When no built-in step
/// (`Brew`, `Pkg`, `LaunchDaemon`, …) fits, supply three closures and a stable id and
/// get a fully reconciled step — drift detection, automatic re-mount, uninstall, and
/// every lifecycle modifier (`.preInstall`, `.priority`, `.loopInterval`, …) — without
/// touching framework internals.
///
/// ```swift
/// Customized("disable-spotlight") {
///     try await ProcessRunner.run("/usr/bin/mdutil", arguments: ["-a", "-i", "off"])
/// } check: {
///     await Spotlight.isDisabled()          // true == desired state already present
/// } unmount: {
///     try await ProcessRunner.run("/usr/bin/mdutil", arguments: ["-a", "-i", "on"])
/// }
/// ```
///
/// - The framework converges to the declared state: `mount` runs only while `check`
///   reports the state is *not* yet present, and re-runs automatically if `check` later
///   reports drift. Write `mount` to be idempotent.
/// - The `id` is the step's stable identity — keep it constant across runs. It survives
///   daemon restarts so a still-declared step is recognized rather than torn down and
///   rebuilt. (A `Customized` removed from the declaration *and* then restarted can't run
///   its `unmount` — the closure no longer exists in the binary — so it is logged and
///   forgotten, the same as a custom `Sys` setting.)
public struct Customized: Setup, Installable {
    public typealias Body = Never

    /// Stable identity for this step. Must not change between runs.
    public let id: String

    let mountAction: @Sendable () async throws -> Void
    let checkAction: @Sendable () async throws -> Bool
    let unmountAction: @Sendable () async throws -> Void

    /// Creates a custom step.
    ///
    /// - Parameters:
    ///   - id: A stable, unique identifier for this step.
    ///   - mount: Brings the system to the desired state. Should be idempotent.
    ///   - check: Returns `true` when the desired state already holds. Drives both the
    ///     skip-if-satisfied optimization on mount and ongoing drift detection.
    ///   - unmount: Reverses `mount` when the step leaves the declaration. Defaults to a no-op.
    public init(
        _ id: String,
        mount: @escaping @Sendable () async throws -> Void,
        check: @escaping @Sendable () async throws -> Bool,
        unmount: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.id = id
        self.mountAction = mount
        self.checkAction = check
        self.unmountAction = unmount
    }
}

extension Customized: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        CustomizedNode(id: id, mount: mountAction, check: checkAction, unmount: unmountAction)
    }
}

extension Customized: _ContentIdentifiable {
    var _contentID: String { "customized:\(id)" }
}
