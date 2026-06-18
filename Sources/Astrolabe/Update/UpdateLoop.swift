import Darwin
import Foundation

/// The actual self-update tick logic. Runs in the updater daemon process,
/// **out of process** from the main convergence engine.
///
/// `tickOnce` is intentionally a pure-ish function (apart from process-side
/// effects: filesystem, network, `execv`), so it can be exercised in tests
/// by substituting a fake `UpdateSource`.
enum UpdateLoop {

    /// Runs the update loop forever: tick, sleep, tick, sleep. Returns only
    /// if the task is cancelled.
    static func run(configuration: UpdateConfiguration, currentVersion: String) async {
        print("[Astrolabe] Update loop started (current version: \(currentVersion), interval: \(configuration.interval)).")
        while !Task.isCancelled {
            await tickOnce(configuration: configuration, currentVersion: currentVersion)
            try? await Task.sleep(for: configuration.interval)
        }
    }

    /// One tick: check the source, download/verify/install if newer, then
    /// kickstart the main daemon and `execv` self.
    static func tickOnce(configuration: UpdateConfiguration, currentVersion: String) async {
        UpdateStatusStorage.setLastCheckedAt(Date())

        // Self-heal the main daemon every tick, independent of whether an update
        // is available — recovers hosts where a prior install left it unloaded
        // (the bootout→bootstrap race). Must run before the "no update" early-return.
        await DaemonManager.ensureLoaded()

        do {
            guard let release = try await configuration.source.latestRelease(channel: configuration.channel) else {
                print("[Astrolabe] Updater: no release available for channel \(configuration.channel.rawValue).")
                UpdateStatusStorage.setLastError(nil)
                return
            }
            UpdateStatusStorage.setLastSeenVersion(release.version)

            guard let local = SemVer(currentVersion) else {
                throw UpdateError.invalidLocalVersion(currentVersion)
            }
            guard let remote = SemVer(release.version) else {
                throw UpdateError.invalidRemoteVersion(release.version)
            }

            if remote == local {
                print("[Astrolabe] Updater: already on \(local) — no update.")
                UpdateStatusStorage.setLastError(nil)
                return
            }
            if remote < local && !configuration.allowDowngrade {
                print("[Astrolabe] Updater: remote \(remote) is older than local \(local); refusing downgrade.")
                UpdateStatusStorage.setLastError(nil)
                return
            }

            print("[Astrolabe] Updater: \(local) → \(remote). Downloading \(release.assetName)...")

            // Download
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("astrolabe-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pkgPath = tempDir.appendingPathComponent(release.assetName)
            let (tempURL, response) = try await URLSession.shared.download(for: release.makeDownloadRequest())
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.downloadFailed(statusCode: http.statusCode)
            }
            try FileManager.default.moveItem(at: tempURL, to: pkgPath)

            // Verify
            try await UpdateVerificationRunner.verify(configuration.verification, pkgPath: pkgPath)

            // Pre-update hook (throwing aborts)
            try await configuration.preUpdate?(currentVersion, release.version)

            // Install — installer is transactional; failure leaves the old binary intact.
            print("[Astrolabe] Updater: running installer...")
            try await ProcessRunner.run("/usr/sbin/installer",
                                        arguments: ["-pkg", pkgPath.path, "-target", "/"])

            // Bookkeeping
            UpdateStatusStorage.setLastUpdatedAt(Date())
            UpdateStatusStorage.setLastError(nil)
            await configuration.postUpdate?(release.version)

            // Restart the main daemon to load the new binary.
            print("[Astrolabe] Updater: kickstarting main daemon \(DaemonManager.label)...")
            try? await LaunchctlHelper.kickstart(label: DaemonManager.label)

            // Re-exec self so the updater also runs the new code. POSIX `execv`
            // replaces the process image in place; launchd keeps our PID and is happy.
            // If `execv` returns, it failed — fall through; launchd's KeepAlive will
            // respawn us with the new binary at the next opportunity.
            print("[Astrolabe] Updater: execv into new binary...")
            execvSelf()
            print("[Astrolabe] Updater: execv returned (unexpected); will exit and rely on launchd to respawn.")

        } catch {
            let message = "\(error)"
            print("[Astrolabe] Updater: tick failed — \(message)")
            UpdateStatusStorage.setLastError(message)
            await configuration.onFail?(error)
        }
    }

    /// Replaces this process's image with a fresh execution of the same binary
    /// path and arguments. Returns only on failure.
    private static func execvSelf() {
        let argv = CommandLine.arguments
        guard let path = argv.first else { return }

        // Build a C-string argv terminated by NULL.
        let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        defer {
            for ptr in cStrings { if let ptr { free(ptr) } }
        }
        var argvWithNull: [UnsafeMutablePointer<CChar>?] = cStrings + [nil]

        _ = argvWithNull.withUnsafeMutableBufferPointer { buf -> Int32 in
            execv(path, buf.baseAddress)
        }
        // execv returns only on failure.
    }
}

// MARK: - Errors

public enum UpdateError: Error, Sendable, CustomStringConvertible {
    case invalidLocalVersion(String)
    case invalidRemoteVersion(String)
    case downloadFailed(statusCode: Int)

    public var description: String {
        switch self {
        case .invalidLocalVersion(let s):  return "Local version is not valid SemVer: \(s)"
        case .invalidRemoteVersion(let s): return "Remote version is not valid SemVer: \(s)"
        case .downloadFailed(let code):    return "Asset download failed with status \(code)"
        }
    }
}
