import Darwin
import Foundation

/// Manages the sibling `<main-label>.updater` LaunchDaemon.
///
/// Symmetric to `DaemonManager` but for the updater daemon, which runs the
/// same binary with the hidden `__update-loop` subcommand. Owns the plist at
/// `/Library/LaunchDaemons/<label>.updater.plist`.
enum UpdaterDaemonManager {
    static var label: String { DaemonManager.label + ".updater" }
    static var plistPath: String { "/Library/LaunchDaemons/\(label).plist" }
    static var logPath: String { "/var/log/\(label).log" }

    /// Installs or updates the updater daemon's plist and bootstraps it via launchd.
    /// Bakes the configured GitHub token into `EnvironmentVariables` so the
    /// out-of-process loop can authenticate API calls.
    static func installOrUpdate(
        executablePath: String,
        configuration: UpdateConfiguration,
        force: Bool = false
    ) async throws {
        let existingPath = daemonBinaryPath()
        if !force, existingPath == executablePath, LaunchctlHelper.isDaemonLoaded(label: label) {
            print("[Astrolabe] Updater daemon already running.")
            return
        }
        if force {
            print("[Astrolabe] Force-installing updater daemon...")
        } else if existingPath != nil, existingPath != executablePath {
            print("[Astrolabe] Updater binary path changed (\(existingPath ?? "?") → \(executablePath)), updating daemon...")
        } else if existingPath == nil {
            print("[Astrolabe] Installing updater daemon...")
        }

        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "__update-loop"],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        if let token = configuration.githubToken, !token.isEmpty {
            plist["EnvironmentVariables"] = ["GITHUB_TOKEN": token]
        }

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        FileManager.default.createFile(atPath: plistPath, contents: data)

        try await LaunchctlHelper.activateDaemon(label: label, plistPath: plistPath)
        print("[Astrolabe] Updater daemon installed (\(label)).")
    }

    /// Removes the updater daemon. No-op if it isn't installed.
    static func remove() async {
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        await LaunchctlHelper.deactivateDaemon(label: label)
        try? FileManager.default.removeItem(atPath: plistPath)
        print("[Astrolabe] Updater daemon removed.")
    }

    /// Reads the existing updater plist and returns the binary path from
    /// `ProgramArguments[0]`. Returns `nil` if no plist exists.
    private static func daemonBinaryPath() -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let path = args.first
        else { return nil }
        return path
    }
}
