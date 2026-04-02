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

    /// Runs `launchctl bootout <domain>/<label>`, ignoring errors.
    static func bootout(domain: String, label: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "\(domain)/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Runs `launchctl enable <domain>/<label>`.
    static func enable(domain: String, label: String) async throws {
        try await ProcessRunner.run("/bin/launchctl", arguments: ["enable", "\(domain)/\(label)"])
    }

    /// Runs `launchctl bootstrap <domain> <plistPath>`.
    static func bootstrap(domain: String, plistPath: String) async throws {
        try await ProcessRunner.run("/bin/launchctl", arguments: ["bootstrap", domain, plistPath])
    }

    // MARK: - Loaded Checks

    /// Returns whether a LaunchDaemon is loaded in the system domain.
    static func isDaemonLoaded(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Returns whether a LaunchAgent is loaded for the active console user.
    /// Returns `true` (skip) if no console user is logged in.
    static func isAgentLoadedForConsoleUser(label: String) -> Bool {
        guard let user = UserHelper.consoleUser() else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(user.uid)/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Daemon Operations

    /// Activates a LaunchDaemon: bootout → enable → bootstrap into system domain.
    static func activateDaemon(label: String, plistPath: String) async throws {
        await bootout(domain: "system", label: label)
        try await enable(domain: "system", label: label)
        try await bootstrap(domain: "system", plistPath: plistPath)
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
            let guiDomain = "gui/\(user.uid)"
            await bootout(domain: guiDomain, label: label)
            try? await enable(domain: guiDomain, label: label)
            // Bootstrap with correct UID context: launchctl asuser <uid> sudo -u <username> launchctl bootstrap gui/<uid> <plist>
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = [
                "asuser", String(user.uid),
                "/usr/bin/sudo", "-u", user.username,
                "/bin/launchctl", "bootstrap", guiDomain, plistPath,
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            // Ignore errors — user may not be logged in
        }
    }

    /// Activates a LaunchAgent for the current console user only: bootout → enable → bootstrap.
    static func activateAgentForConsoleUser(label: String, plistPath: String) async {
        guard let user = UserHelper.consoleUser() else { return }
        let guiDomain = "gui/\(user.uid)"
        await bootout(domain: guiDomain, label: label)
        try? await enable(domain: guiDomain, label: label)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "asuser", String(user.uid),
            "/usr/bin/sudo", "-u", user.username,
            "/bin/launchctl", "bootstrap", guiDomain, plistPath,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Deactivates a LaunchAgent for all users: bootout per user.
    static func deactivateAgentForAllUsers(label: String) async {
        for user in UserHelper.allUsers() {
            await bootout(domain: "gui/\(user.uid)", label: label)
        }
    }
}
