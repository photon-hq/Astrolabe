import Foundation
import Semaphore
import SystemConfiguration

/// Brew-specific utilities. Owns the brew semaphore for serialization.
enum BrewHelper {

    /// Serializes all brew operations (brew uses internal locks that conflict under parallelism).
    private static let semaphore = AsyncSemaphore(value: 1)

    static var path: String {
        #if arch(arm64)
        "/opt/homebrew/bin/brew"
        #else
        "/usr/local/bin/brew"
        #endif
    }

    /// Looks up the current console user (brew refuses to run as root).
    static func consoleUser() -> String? {
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else {
            return nil
        }
        return username
    }

    /// Checks whether a brew package is installed.
    static func isInstalled(_ name: String, flag: String, user: String?) -> Bool {
        let process = Process()
        if let user {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-u", user, path, "list", flag, name]
        } else {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["list", flag, name]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs a brew command as the console user, serialized via semaphore.
    static func run(_ arguments: [String], user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        if let user {
            try await ProcessRunner.run("/usr/bin/sudo", arguments: ["-u", user, path] + arguments)
        } else {
            try await ProcessRunner.run(path, arguments: arguments)
        }
    }

    /// Checks and installs atomically under the brew semaphore.
    /// Prevents lock conflicts between `brew list` and concurrent `brew install`.
    static func installIfNeeded(_ name: String, type: BrewInfo.BrewType, user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        let flag = type == .cask ? "--cask" : "--formula"
        if isInstalled(name, flag: flag, user: user) {
            print("[Astrolabe] \(name) already installed, skipping.")
            return
        }

        var args = ["install"]
        if type == .cask { args.append("--cask") }
        args.append(name)

        let userDesc = user.map { "as \($0)" } ?? "as root"
        print("[Astrolabe] Installing \(flag.dropFirst(2)) \(name) \(userDesc)...")

        if let user {
            try await ProcessRunner.run("/usr/bin/sudo", arguments: ["-u", user, path] + args)
        } else {
            try await ProcessRunner.run(path, arguments: args)
        }
        print("[Astrolabe] Installed \(name).")
    }

    /// Uninstalls a brew package, serialized via semaphore.
    static func uninstall(_ name: String, cask: Bool) async throws {
        let flag = cask ? "--cask" : "--formula"
        guard isInstalled(name, flag: flag, user: consoleUser()) else { return }
        var args = ["uninstall"]
        if cask { args.append("--cask") }
        args.append(name)
        try await run(args, user: consoleUser())
    }
}
