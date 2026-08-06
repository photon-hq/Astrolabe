import Foundation
import Subprocess

/// The credentials and environment needed to run a child process *as* a local user.
///
/// This is the structured replacement for prefixing a command with `/usr/bin/sudo -u <name>`.
/// `sudo` does three separable things that all have to be reproduced explicitly, because
/// `PlatformOptions` on its own only changes the process credentials:
///
/// 1. **Credentials.** `sudo` calls `initgroups()`, which installs the target user's
///    *supplementary* groups. Subprocess only calls `setgroups()` when
///    `PlatformOptions.supplementaryGroups` is non-empty — so passing `userID` alone would
///    leave the child holding root's groups (`wheel`, `operator`, …) while running as the
///    user. `supplementaryGroups` is mandatory here, not an optimization.
/// 2. **Environment.** `sudo` resets `HOME`, `USER`, `LOGNAME` and `SHELL` to the target
///    user. Nothing in `PlatformOptions` touches the environment, so a naive port would
///    hand Homebrew `HOME=/var/root` and send its cache to the wrong place.
/// 3. **Path.** `sudo` applies `secure_path`. We prepend explicitly instead.
///
/// This does not replace `launchctl asuser <uid> …`. That selects the user's Mach bootstrap
/// namespace (needed to reach WindowServer / Apple Events) which is a launchd concept, not a
/// credential one — see `LaunchctlHelper.runOsascript`.
struct UserContext: Sendable {
    let name: String
    let uid: uid_t
    let gid: gid_t
    let home: String
    let shell: String
    /// The user's supplementary groups, as `initgroups()` would install them.
    let supplementaryGroups: [gid_t]
    /// A directory to place at the front of `PATH`, if any.
    private(set) var pathPrefix: String?

    /// Resolves a user from the password database. Returns `nil` if the user does not exist.
    init?(username: String) {
        guard let pw = getpwnam(username) else { return nil }
        self.name = String(cString: pw.pointee.pw_name)
        self.uid = pw.pointee.pw_uid
        self.gid = pw.pointee.pw_gid
        self.home = String(cString: pw.pointee.pw_dir)
        self.shell = String(cString: pw.pointee.pw_shell)
        self.supplementaryGroups = Self.supplementaryGroups(for: self.name, gid: self.gid)
    }

    /// Process credentials for this user: real/effective uid, gid, and supplementary groups.
    var platformOptions: PlatformOptions {
        var options = PlatformOptions()
        options.userID = uid
        options.groupID = gid
        options.supplementaryGroups = supplementaryGroups
        return options
    }

    /// Returns a copy that puts `directory` at the front of the child's `PATH`.
    ///
    /// Used to place the Homebrew prefix ahead of the daemon's inherited system path, so
    /// brew finds its own bundled tools.
    func prependingPath(_ directory: String) -> UserContext {
        var copy = self
        copy.pathPrefix = directory
        return copy
    }

    /// The environment `sudo -u <name>` would hand the child.
    ///
    /// Qualified because Astrolabe has its own `Environment` — the `@Environment` property
    /// wrapper — which is generic and would win unqualified lookup.
    func environment() -> Subprocess.Environment {
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if let prefix = pathPrefix, !path.split(separator: ":").contains(Substring(prefix)) {
            path = "\(prefix):\(path)"
        }
        return .inherit.updating([
            "HOME": home,
            "USER": name,
            "LOGNAME": name,
            "SHELL": shell,
            "PATH": path,
        ])
    }

    // MARK: - Private

    /// Wraps `getgrouplist(3)`, growing the buffer until every group fits.
    ///
    /// Darwin's `getgrouplist` fills as many groups as the buffer holds and returns -1 when
    /// there are more, so a truncated read is silent — and a truncated group list means the
    /// child silently loses access it should have. Grow rather than accept the truncation.
    private static func supplementaryGroups(for name: String, gid: gid_t) -> [gid_t] {
        var capacity: Int32 = 32
        let baseGID = Int32(bitPattern: gid)

        while capacity <= 1024 {
            var count = capacity
            var buffer = [Int32](repeating: 0, count: Int(capacity))
            let result = name.withCString { getgrouplist($0, baseGID, &buffer, &count) }
            if result != -1 {
                return buffer.prefix(Int(count)).map { gid_t(bitPattern: $0) }
            }
            // `count` holds the required size on failure; grow past it and retry.
            capacity = max(count, capacity * 2)
        }

        // Pathological group count — fall back to the primary group alone rather than
        // handing the child a partial list.
        return [gid]
    }
}
