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
        // Compare against the existing plist *before* overwriting so activation
        // can take the race-free `kickstart` fast path when nothing changed.
        let plistChanged = plistDiffers(at: plistPath, from: plist)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        FileManager.default.createFile(atPath: plistPath, contents: data)

        try await LaunchctlHelper.activateDaemon(label: label, plistPath: plistPath, plistChanged: plistChanged)

        print("[Astrolabe] Daemon started. Exiting — launchd will manage the process.")
    }

    /// Self-heal: if the daemon's plist is installed but the job isn't loaded
    /// (e.g. a prior install hit the bootout→bootstrap race), re-activate it.
    /// Idempotent and safe to call on every tick from the updater daemon.
    static func ensureLoaded() async {
        guard FileManager.default.fileExists(atPath: plistPath),
              !LaunchctlHelper.isDaemonLoaded(label: label)
        else { return }
        print("[Astrolabe] \(label) plist present but not loaded — re-activating (self-heal).")
        try? await LaunchctlHelper.activateDaemon(label: label, plistPath: plistPath, plistChanged: false)
    }

    /// True if the on-disk plist is absent or semantically different from
    /// `candidate`. Conservative: returns `true` (forcing a full reload) when the
    /// existing plist can't be read or parsed.
    static func plistDiffers(at path: String, from candidate: [String: Any]) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return true }
        // Deep, order-independent comparison; NSDictionary == bridges Bool→CFBoolean correctly.
        return (existing as NSDictionary) != (candidate as NSDictionary)
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
