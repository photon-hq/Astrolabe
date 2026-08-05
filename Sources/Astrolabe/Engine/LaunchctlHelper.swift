import Foundation

/// Utilities for generating launchd plists and running launchctl commands.
enum LaunchctlHelper {

    // MARK: - Plist Generation

    /// Builds a launchd plist dictionary from label, program arguments, and current environment values.
    static func buildPlist(label: String, programArguments: [String], environment: EnvironmentValues) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
        ]

        if let keepAlive = environment.launchdKeepAlive {
            plist["KeepAlive"] = keepAlive
        }
        if let runAtLoad = environment.launchdRunAtLoad {
            plist["RunAtLoad"] = runAtLoad
        }
        if let startInterval = environment.launchdStartInterval {
            plist["StartInterval"] = startInterval
        }
        if let standardOutPath = environment.launchdStandardOutPath {
            plist["StandardOutPath"] = standardOutPath
        }
        if let standardErrorPath = environment.launchdStandardErrorPath {
            plist["StandardErrorPath"] = standardErrorPath
        }
        if let workingDirectory = environment.launchdWorkingDirectory {
            plist["WorkingDirectory"] = workingDirectory
        }
        if let environmentVariables = environment.launchdEnvironmentVariables {
            plist["EnvironmentVariables"] = environmentVariables
        }
        if let throttleInterval = environment.launchdThrottleInterval {
            plist["ThrottleInterval"] = throttleInterval
        }

        return plist
    }

    /// Serializes a plist dictionary to XML data.
    static func serializePlist(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: - launchctl Commands

    static let launchctl = "/bin/launchctl"

    /// Runs a `launchctl` subcommand and reports only whether it succeeded.
    ///
    /// Used by the `print`-based existence probes, where a non-zero status *is* the answer
    /// rather than a failure. A spawn error counts as "not loaded".
    private static func succeeds(_ arguments: [String]) async -> Bool {
        let result = try? await ProcessRunner.capture(launchctl, arguments: arguments)
        return result?.isSuccess ?? false
    }

    /// Runs `launchctl bootout <domain>/<label>`, ignoring errors.
    static func bootout(domain: String, label: String) async {
        _ = try? await ProcessRunner.capture(
            launchctl, arguments: ["bootout", "\(domain)/\(label)"],
            timeout: ProcessRunner.Timeout.mutation
        )
    }

    /// Runs `launchctl enable <domain>/<label>`.
    static func enable(domain: String, label: String) async throws {
        try await ProcessRunner.run(launchctl, arguments: ["enable", "\(domain)/\(label)"])
    }

    /// Runs `launchctl bootstrap <domain> <plistPath>`.
    static func bootstrap(domain: String, plistPath: String) async throws {
        try await ProcessRunner.run(launchctl, arguments: ["bootstrap", domain, plistPath])
    }

    /// Runs `launchctl kickstart -k <domain>/<label>`: SIGTERM the running job,
    /// then have launchd respawn it. Used to make a daemon pick up a replaced binary.
    static func kickstart(domain: String = "system", label: String) async throws {
        try await ProcessRunner.run(launchctl, arguments: ["kickstart", "-k", "\(domain)/\(label)"])
    }

    // MARK: - Loaded Checks

    /// Returns whether a LaunchDaemon is loaded in the system domain.
    static func isDaemonLoaded(label: String) async -> Bool {
        await succeeds(["print", "system/\(label)"])
    }

    /// Returns whether a LaunchAgent is loaded for all active GUI users.
    /// Returns `true` (skip) if no GUI sessions exist.
    static func isAgentLoadedForActiveGUIUsers(label: String) async -> Bool {
        let users = await activeGUIUsers()
        guard !users.isEmpty else { return true }
        for user in users {
            guard await succeeds(["print", "gui/\(user.uid)/\(label)"]) else { return false }
        }
        return true
    }

    // MARK: - Daemon Operations

    /// Activates a LaunchDaemon, robust against the well-known bootout→bootstrap
    /// race where the previous, still-draining instance blocks re-bootstrapping
    /// the same label (`Bootstrap failed: 5: Input/output error`).
    ///
    /// - When already loaded with an unchanged plist, prefers an atomic
    ///   `kickstart -k`: no unload window, no race, and it picks up a replaced
    ///   binary at the same `ProgramArguments` path.
    /// - Otherwise: bootout (only if loaded) → wait until the job is actually
    ///   gone → enable → bootstrap, retrying transient failures.
    ///
    /// Always verifies the daemon is loaded afterward and never leaves it
    /// silently unloaded.
    static func activateDaemon(label: String, plistPath: String, plistChanged: Bool = true) async throws {
        if await isDaemonLoaded(label: label), !plistChanged {
            // Fast path: in-place restart. Falls through to a full reload if the
            // job vanished from under us.
            if (try? await kickstart(label: label)) != nil,
               await waitForDaemon(label: label, loaded: true) {
                return
            }
        }

        if await isDaemonLoaded(label: label) {
            await bootout(domain: "system", label: label)
            // `bootout` only waits on the launchctl *process*, not the job's
            // teardown — wait for launchd to actually drop it before bootstrapping.
            // If it never unloads, fail fast: bootstrapping over a still-loaded
            // job would let bootstrapWithRetry's `isDaemonLoaded` check mistake the
            // stale instance for a successful load.
            guard await waitForDaemon(label: label, loaded: false) else {
                throw AstrolabeError.daemonInstallFailed(
                    "Daemon \(label) did not unload after bootout; refusing to bootstrap over the draining job.")
            }
        }
        try await enable(domain: "system", label: label)
        try await bootstrapWithRetry(domain: "system", label: label, plistPath: plistPath)

        guard await waitForDaemon(label: label, loaded: true) else {
            throw AstrolabeError.daemonInstallFailed(
                "Daemon \(label) did not load after activation (plist: \(plistPath)).")
        }
    }

    /// Runs `bootstrap`, retrying on transient launchd failures — chiefly the
    /// EIO returned while a just-booted-out instance is still draining. Treats a
    /// label that became loaded mid-retry as success.
    private static func bootstrapWithRetry(
        domain: String,
        label: String,
        plistPath: String,
        attempts: Int = 5
    ) async throws {
        var delay: Duration = .milliseconds(500)
        for attempt in 1...attempts {
            do {
                try await bootstrap(domain: domain, plistPath: plistPath)
                return
            } catch {
                // Some EIO failures still register the job; if it's loaded, we're done.
                if await isDaemonLoaded(label: label) { return }
                guard attempt < attempts, isTransientLaunchctlError(error) else { throw error }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(2))
            }
        }
    }

    /// Polls `isDaemonLoaded` until it equals `loaded`, or the timeout elapses.
    /// Returns whether the desired state was reached.
    @discardableResult
    static func waitForDaemon(
        label: String,
        loaded: Bool,
        timeout: Duration = .seconds(10),
        interval: Duration = .milliseconds(250)
    ) async -> Bool {
        var waited: Duration = .zero
        while waited < timeout {
            if await isDaemonLoaded(label: label) == loaded { return true }
            try? await Task.sleep(for: interval)
            waited += interval
        }
        return await isDaemonLoaded(label: label) == loaded
    }

    /// Whether a failed launchctl invocation looks transient and worth retrying.
    static func isTransientLaunchctlError(_ error: any Error) -> Bool {
        guard case ReconcileError.processFailed(_, _, let output) = error else { return false }
        return output.contains("Input/output error")        // errno 5 — prior job still draining
            || output.contains("Operation now in progress")  // errno 37
    }

    /// Deactivates a LaunchDaemon: bootout from system domain.
    static func deactivateDaemon(label: String) async {
        await bootout(domain: "system", label: label)
    }

    // MARK: - Agent Operations

    /// Activates a LaunchAgent for all users: bootout → enable → bootstrap per user.
    /// Uses `launchctl asuser <uid> sudo -u <username>` pattern from macrocosm.
    static func activateAgentForAllUsers(label: String, plistPath: String) async {
        for user in UserHelper.allUsers() {
            await bootstrapAgent(for: user, label: label, plistPath: plistPath)
        }
    }

    /// Activates a LaunchAgent for all active GUI users: bootout → enable → bootstrap per user.
    static func activateAgentForActiveGUIUsers(label: String, plistPath: String) async {
        for user in await activeGUIUsers() {
            await bootstrapAgent(for: user, label: label, plistPath: plistPath)
        }
    }

    /// bootout → enable → bootstrap a LaunchAgent into one user's GUI domain.
    ///
    /// Errors are ignored throughout: the user may simply not be logged in.
    private static func bootstrapAgent(
        for user: UserHelper.User,
        label: String,
        plistPath: String
    ) async {
        let guiDomain = "gui/\(user.uid)"
        await bootout(domain: guiDomain, label: label)
        try? await enable(domain: guiDomain, label: label)

        // `asuser` puts the invocation in the user's Mach bootstrap namespace and `sudo`
        // drops the credentials — this chain cannot be replaced by `PlatformOptions.userID`,
        // which changes credentials but not the bootstrap namespace.
        _ = try? await ProcessRunner.capture(
            launchctl,
            arguments: [
                "asuser", String(user.uid),
                "/usr/bin/sudo", "-u", user.username,
                launchctl, "bootstrap", guiDomain, plistPath,
            ],
            timeout: ProcessRunner.Timeout.mutation
        )
    }

    /// Returns users that have an active GUI session (`gui/<uid>` domain exists).
    static func activeGUIUsers() async -> [UserHelper.User] {
        var active: [UserHelper.User] = []
        for user in UserHelper.allUsers() {
            if await succeeds(["print", "gui/\(user.uid)"]) { active.append(user) }
        }
        return active
    }

    /// Deactivates a LaunchAgent for all users: bootout per user.
    static func deactivateAgentForAllUsers(label: String) async {
        for user in UserHelper.allUsers() {
            await bootout(domain: "gui/\(user.uid)", label: label)
        }
    }

    // MARK: - GUI Session Helpers

    /// Polls until `launchctl print gui/<uid>` succeeds, indicating the GUI session is available.
    ///
    /// - Parameter timeout: How long to keep polling. `nil` waits indefinitely, which is the
    ///   default because a daemon started before anyone logs in should keep waiting rather
    ///   than give up. Cancelling the enclosing task still breaks the loop.
    /// - Returns: `true` once the session is available, `false` if the timeout elapsed first.
    @discardableResult
    static func waitForGUISession(uid: uid_t = 501, timeout: Duration? = nil) async throws -> Bool {
        var waited: Duration = .zero
        let interval: Duration = .seconds(2)
        while true {
            if await succeeds(["print", "gui/\(uid)"]) { return true }
            if let timeout, waited >= timeout { return false }
            try await Task.sleep(for: interval)
            waited += interval
        }
    }

    /// Runs `/usr/bin/osascript` via `launchctl asuser <uid> sudo -H -u <username>`
    /// for GUI access from a daemon.
    ///
    /// Deliberately unbounded: an `osascript` dialog blocks until a human dismisses it, so a
    /// timeout here would cancel the very thing we are waiting for.
    static func runOsascript(
        uid: uid_t = 501,
        arguments: [String]
    ) async -> (terminationStatus: Int32, output: String) {
        let username = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "#\(uid)"

        // `asuser` selects the user's Mach bootstrap namespace, which is what gives osascript
        // reach into WindowServer and Apple Events. `PlatformOptions.userID` changes
        // credentials only, so this chain stays as-is.
        guard let result = try? await ProcessRunner.capture(
            launchctl,
            arguments: [
                "asuser", String(uid),
                "/usr/bin/sudo", "-H", "-u", username,
                "/usr/bin/osascript",
            ] + arguments,
            timeout: nil
        ) else {
            return (-1, "")
        }

        return (
            result.exitCode,
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
