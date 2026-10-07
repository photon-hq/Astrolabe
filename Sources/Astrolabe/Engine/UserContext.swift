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
///    user. `supplementaryGroups` is mandatory here, not an optimization. It is also capped
///    at `NGROUPS_MAX`, which `initgroups()` did silently — see `prioritized(_:primary:limit:name:)`.
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
    /// The user's groups for `setgroups()`: at most `NGROUPS_MAX`, primary group first.
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
        let all = Self.supplementaryGroups(for: self.name, gid: self.gid)
        let kept = Self.prioritized(all, primary: self.gid, name: Self.groupName)
        let dropped = Set(all).subtracting(kept)
        if !dropped.isEmpty {
            let names = all.filter(dropped.contains).map { Self.groupName($0) ?? String($0) }
            print("[Astrolabe] \(self.name) is in \(Set(all).count) groups; dropping \(dropped.count) past NGROUPS_MAX (\(NGROUPS_MAX)) when running as \(self.name): \(names.joined(separator: ", "))")
        }
        self.supplementaryGroups = kept
    }

    /// Orders a user's groups for `setgroups()` and caps them at `limit`.
    ///
    /// Darwin's `setgroups()` rejects more than `NGROUPS_MAX` (16) groups with `EINVAL`, so the
    /// spawn fails before the child runs. `initgroups()`, which `sudo` uses, truncates quietly
    /// instead. On system412 (ENG-3374) a leftover File Sharing group put the brew user in 17
    /// groups and every brew install failed; provisioned hosts are at 21, because each share
    /// point's group nests `everyone`.
    ///
    /// Which groups survive matters, because `setgroups()` also opts the child out of the
    /// dynamic membership checks `initgroups()` arranges: a dropped group is truly gone for
    /// it. So the order is:
    ///
    /// 1. `primary`, always first: the kernel keeps the effective group in the list's first slot.
    /// 2. `admin`, then `staff`: what Homebrew's prefix and the user's own files are shared through.
    /// 3. Every other group, in the order given.
    /// 4. Last, `com.apple.sharepoint.*` and `com.apple.access_*`. They only gate File Sharing
    ///    share points and remote-access services (SSH, Screen Sharing), which a spawned child
    ///    never uses.
    ///
    /// Duplicates keep their first position. `name` resolves a gid to its group name.
    static func prioritized(
        _ groups: [gid_t],
        primary: gid_t,
        limit: Int = Int(NGROUPS_MAX),
        name: (gid_t) -> String?
    ) -> [gid_t] {
        func rank(_ gid: gid_t) -> Int {
            if gid == primary { return 0 }
            switch name(gid) {
            case "admin": return 1
            case "staff": return 2
            case let group? where group.hasPrefix("com.apple.sharepoint.") || group.hasPrefix("com.apple.access_"):
                return 4
            default: return 3
            }
        }
        var seen = Set<gid_t>()
        let unique = ([primary] + groups).filter { seen.insert($0).inserted }
        let ordered = unique.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        return Array(ordered.prefix(max(0, limit)))
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

    private static func groupName(_ gid: gid_t) -> String? {
        guard let group = getgrgid(gid) else { return nil }
        return String(cString: group.pointee.gr_name)
    }

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
