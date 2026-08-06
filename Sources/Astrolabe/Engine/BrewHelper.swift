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

    /// Checks whether a brew package is installed, by reading the Cellar/Caskroom.
    ///
    /// `brew list <name>` answers this question by consulting exactly these directories, but
    /// pays a Ruby interpreter startup (~0.4s warm) to do it. That is affordable once during
    /// `mount`; on the drift loop it was the daemon's most-spawned subprocess, since every
    /// `Brew` leaf re-checks on its own `loopInterval` — 15s by default.
    ///
    /// Reading the directories directly also drops three hazards the subprocess carried. It
    /// cannot time out, which matters because a timed-out `brew list` read as "not installed"
    /// and cost a full reinstall. It cannot contend with a concurrent `brew install` on
    /// Homebrew's lockfile, which the drift-loop call did — it ran outside the semaphore. And
    /// it needs no credential drop: the prefix is world-readable, so the root daemon reads it
    /// without `userContext`.
    ///
    /// The predicate matches Homebrew's own — installed means *at least one non-empty version
    /// directory*. Existence alone is not enough: an interrupted uninstall leaves an empty
    /// `Cellar/<name>` behind, and `brew list --formula <name>` exits non-zero for one. (Bulk
    /// `brew list --formula` does print such leftovers, so the per-package query this replaces
    /// was the stricter of brew's two answers, and this keeps that stricter reading.)
    ///
    /// - Parameter prefix: The Homebrew prefix to read. Injectable for tests only.
    static func isInstalled(
        _ name: String,
        type: Brew.PackageType,
        prefix: String = BrewHelper.prefix
    ) -> Bool {
        // Cellar and Caskroom key on the bare token — a tap-qualified name has no directory.
        let root = "\(prefix)/\(type == .cask ? "Caskroom" : "Cellar")/\(shortName(name))"
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return false }
        return versions.contains { version in
            // A cask's `.metadata` holds its install receipts and outlives an uninstall —
            // bookkeeping, not an installed version.
            guard version != ".metadata" else { return false }
            // Non-empty *and* a directory: `contentsOfDirectory` throws on a plain file, so a
            // stray `.DS_Store` at this level cannot read as a version.
            let contents = try? fileManager.contentsOfDirectory(atPath: "\(root)/\(version)")
            return contents?.isEmpty == false
        }
    }

    /// Runs a brew command as the console user, serialized via semaphore.
    static func run(_ arguments: [String], user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }
        try await execute(arguments, user: user)
    }

    /// Checks and installs atomically under the brew semaphore.
    ///
    /// The check no longer needs the semaphore on its own — it reads the Cellar/Caskroom
    /// rather than shelling out — but holding it across check-then-install still does: it
    /// stops two mounts of the same package from both observing "absent" and racing two
    /// `brew install`s onto Homebrew's lockfile.
    static func installIfNeeded(_ name: String, type: Brew.PackageType, user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        if isInstalled(name, type: type) {
            print("[Astrolabe] \(name) already installed, skipping.")
            return
        }

        var args = ["install"]
        if type == .cask { args.append("--cask") }
        args.append(name)

        let kind = type == .cask ? "cask" : "formula"
        let userDesc = user.map { "as \($0)" } ?? "as root"
        print("[Astrolabe] Installing \(kind) \(name) \(userDesc)...")

        try await execute(args, user: user)
        print("[Astrolabe] Installed \(name).")
    }

    /// Uninstalls a brew package, serialized via semaphore.
    static func uninstall(_ name: String, cask: Bool) async throws {
        guard isInstalled(name, type: cask ? .cask : .formula) else { return }
        var args = ["uninstall"]
        if cask { args.append("--cask") }
        args.append(name)
        try await run(args, user: brewUser())
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
