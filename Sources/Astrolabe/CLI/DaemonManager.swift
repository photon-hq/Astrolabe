import Darwin
import Foundation

enum DaemonManager {
    static let label = "codes.photon.astrolabe"
    static let plistPath = "/Library/LaunchDaemons/codes.photon.astrolabe.plist"

    /// True when the process was started by launchd (parent PID is 1).
    static var isLaunchdChild: Bool { getppid() == 1 }

    /// Installs or updates the LaunchDaemon plist and bootstraps it via launchd.
    /// The calling process should exit after this returns — launchd manages the daemon.
    /// When `force` is true, the plist is always overwritten and the daemon re-bootstrapped.
    static func installOrUpdateDaemon(force: Bool = false) async throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw AstrolabeError.daemonInstallFailed("Could not resolve executable path.")
        }

        if force {
            print("[Astrolabe] Force-installing LaunchDaemon...")
        } else if let existingPath = daemonBinaryPath() {
            if existingPath == executablePath {
                if LaunchctlHelper.isDaemonLoaded(label: label) {
                    print("[Astrolabe] Daemon already running.")
                    return
                }
            } else {
                print("[Astrolabe] Binary path changed (\(existingPath) → \(executablePath)), updating daemon...")
            }
        } else {
            print("[Astrolabe] Installing LaunchDaemon...")
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": "/var/log/\(label).log",
            "StandardErrorPath": "/var/log/\(label).log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        FileManager.default.createFile(atPath: plistPath, contents: data)

        try await LaunchctlHelper.activateDaemon(label: label, plistPath: plistPath)

        print("[Astrolabe] Daemon started. Exiting — launchd will manage the process.")
    }

    /// Removes the LaunchDaemon if one is installed. No-op otherwise.
    static func removeDaemon() async {
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        await LaunchctlHelper.deactivateDaemon(label: label)
        try? FileManager.default.removeItem(atPath: plistPath)
        print("[Astrolabe] LaunchDaemon removed.")
    }

    /// Reads the existing plist and returns the binary path from ProgramArguments[0].
    private static func daemonBinaryPath() -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let path = args.first
        else { return nil }
        return path
    }
}
