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

    static var prefix: String {
        #if arch(arm64)
        "/opt/homebrew"
        #else
        "/usr/local/Homebrew"
        #endif
    }

    /// Resolves the user who should run brew commands.
    /// Primary: owner of the Homebrew prefix directory.
    /// Fallback: the current console user (for bootstrap before Homebrew exists).
    static func brewUser() -> String? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: prefix),
           let uid = attrs[.ownerAccountID] as? NSNumber {
            let uidValue = uid.uint32Value
            if uidValue != 0, let pw = getpwuid(uidValue) {
                return String(cString: pw.pointee.pw_name)
            }
        }
        // Fallback: console user (prefix may not exist yet during bootstrap)
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else { return nil }
        return username
    }

    /// Extracts the short formula/cask name from a potentially tap-qualified name.
    /// e.g. `cloudflare/cloudflare/cloudflared` → `cloudflared`, `wget` → `wget`
    static func shortName(_ name: String) -> String {
        let components = name.split(separator: "/")
        // Tap-qualified names have 3 components: user/tap/formula
        if components.count == 3 {
            return String(components[2])
        }
        return name
    }

    /// Resolves the credentials and environment brew should run under.
    ///
    /// Replaces the old `/usr/bin/sudo -u <user> brew …` prefix. `sudo` was doing three
    /// things — dropping credentials, installing the user's supplementary groups, and
    /// resetting `HOME`/`USER`/`LOGNAME`/`SHELL` — and `UserContext` reproduces all three
    /// explicitly. `HOME` matters most here: Homebrew derives its cache path from it, so
    /// inheriting the daemon's `/var/root` would put downloads in the wrong place.
    ///
    /// Returns `nil` when brew should run as the current user (root, in the daemon).
    static func userContext(_ user: String?) -> UserContext? {
        user.flatMap { UserContext(username: $0)?.prependingPath("\(prefix)/bin") }
    }

    /// Checks whether a brew package is installed.
    static func isInstalled(_ name: String, flag: String, user: String?) async -> Bool {
        // Use short name for `brew list` — tap-qualified names can cause
        // spurious failures when brew tries to resolve the tap remotely.
        let listName = shortName(name)
        // Deliberately not the short probe timeout: a timed-out `brew list` reads as "not
        // installed", which costs a full reinstall. A cold brew can take a while to answer.
        let result = try? await ProcessRunner.capture(
            path,
            arguments: ["list", flag, listName],
            as: userContext(user),
            timeout: ProcessRunner.Timeout.mutation
        )
        return result?.isSuccess ?? false
    }

    /// Runs a brew command as the console user, serialized via semaphore.
    static func run(_ arguments: [String], user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }
        try await execute(arguments, user: user)
    }

    /// Checks and installs atomically under the brew semaphore.
    /// Prevents lock conflicts between `brew list` and concurrent `brew install`.
    static func installIfNeeded(_ name: String, type: Brew.PackageType, user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        let flag = type == .cask ? "--cask" : "--formula"
        if await isInstalled(name, flag: flag, user: user) {
            print("[Astrolabe] \(name) already installed, skipping.")
            return
        }

        var args = ["install"]
        if type == .cask { args.append("--cask") }
        args.append(name)

        let userDesc = user.map { "as \($0)" } ?? "as root"
        print("[Astrolabe] Installing \(flag.dropFirst(2)) \(name) \(userDesc)...")

        try await execute(args, user: user)
        print("[Astrolabe] Installed \(name).")
    }

    /// Uninstalls a brew package, serialized via semaphore.
    static func uninstall(_ name: String, cask: Bool) async throws {
        let flag = cask ? "--cask" : "--formula"
        let user = brewUser()
        guard await isInstalled(name, flag: flag, user: user) else { return }
        var args = ["uninstall"]
        if cask { args.append("--cask") }
        args.append(name)
        try await run(args, user: user)
    }

    // MARK: - Private

    /// Runs brew with output streamed rather than collected.
    ///
    /// `brew install` is verbose and slow enough that buffering it would risk
    /// `outputLimitExceeded` and leave a multi-minute install silent; streaming echoes
    /// progress and keeps only a bounded tail for the error message.
    private static func execute(_ arguments: [String], user: String?) async throws {
        try await ProcessRunner.stream(
            path,
            arguments: arguments,
            as: userContext(user)
        ) { line in
            print("[Astrolabe] brew: \(line)")
        }
    }
}
