import Darwin
import Foundation

/// Everything Homebrew does on the Mac. Tests bind a fake through `HomebrewContext`, so they
/// never run `install.sh` or `chown` anything.
protocol HomebrewSystem: Sendable {
    /// `sysctl hw.optional.arm64` is 1: Apple silicon, even when the daemon runs under Rosetta.
    func isAppleSilicon() -> Bool

    /// From the password database. `nil` when there's no such user.
    func uid(of user: String) -> uid_t?

    /// Every account that owns part of Homebrew, sorted, without duplicates: the `owners` fact's
    /// reading. `lstat` of the prefix, of `Cellar`, `Caskroom`, `opt` and `bin`, and of each entry
    /// directly inside them; an owner with no account reads as `#<uid>`. `[]` when `bin/brew`
    /// isn't executable. Throws when a directory that's there can't be read, so a hiccup never
    /// reads as "not installed".
    func owners() throws -> [String]

    /// Creates `/opt/homebrew`, owned by root, when it isn't there. `install.sh` can't: `/opt`
    /// is root's, and it would need `sudo`.
    func createPrefix() throws

    /// `chown -R -P <user> /opt/homebrew`: never follows a link, out of the prefix or in it.
    /// Groups and modes stay as they are.
    func reown(_ user: String) async throws

    /// Fetches Homebrew's `install.sh` and runs it as `user` with `NONINTERACTIVE=1`, streamed
    /// to the log. It refuses root, and needs no `sudo` once `user` owns the prefix.
    func runInstallScript(as user: String) async throws

    /// Writes `/etc/paths.d/homebrew`, so every shell finds `brew`. `install.sh` skips it
    /// without `sudo`.
    func addToPaths() throws

    /// `brew --version` as `user`, with the prefix first on `PATH`. `nil` when it exits non-zero;
    /// throws only when it can't run at all.
    func brewVersion(as user: String) async throws -> String?
}

/// The real `HomebrewSystem`: Homebrew's own `install.sh`, run as the owner.
struct InstallScriptHomebrew: HomebrewSystem {
    static let prefix = "/opt/homebrew"
    static let brew = "\(prefix)/bin/brew"
    /// Where every `brew install` creates something, so a `brew` run as another user shows.
    static let watched = ["Cellar", "Caskroom", "opt", "bin"]
    static let installScript = URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")!
    static let pathsFile = "/etc/paths.d/homebrew"

    func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    func uid(of user: String) -> uid_t? {
        Self.account(named: user)
    }

    func owners() throws -> [String] {
        guard access(Self.brew, X_OK) == 0 else { return [] }
        var uids: Set<uid_t> = []
        if let prefix = try Self.entry(Self.prefix) { uids.insert(prefix.st_uid) }
        for area in Self.watched {
            let directory = "\(Self.prefix)/\(area)"
            guard let info = try Self.entry(directory) else { continue }
            uids.insert(info.st_uid)
            // A link in place of the directory counts by its own owner: never list what it points at.
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
                if let entry = try Self.entry("\(directory)/\(name)") { uids.insert(entry.st_uid) }
            }
        }
        return Set(uids.map(Self.userName)).sorted()
    }

    func createPrefix() throws {
        // `install.sh` would make it 0755 too, and it sets the group itself.
        guard mkdir(Self.prefix, 0o755) == 0 || errno == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func reown(_ user: String) async throws {
        // A big prefix has hundreds of thousands of files.
        try await ProcessRunner.run("/usr/sbin/chown", arguments: ["-R", "-P", user, Self.prefix], timeout: .seconds(15 * 60))
    }

    func runInstallScript(as user: String) async throws {
        guard let context = UserContext(username: user)?.setting(["NONINTERACTIVE": "1"]) else {
            throw HomebrewError.unknownOwner(user)
        }
        let (data, response) = try await URLSession.shared.data(from: Self.installScript)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let script = String(data: data, encoding: .utf8), !script.isEmpty else {
            throw HomebrewError.installScriptUnavailable(status: status)
        }
        print("[Astrolabe] installing Homebrew as \(user)")
        // What Homebrew documents, `/bin/bash -c "$(curl -fsSL …/install.sh)"`, minus a silent
        // no-op when the fetch fails.
        try await ProcessRunner.stream("/bin/bash", arguments: ["-c", script], as: context, timeout: ProcessRunner.Timeout.install) { line in
            print("[Astrolabe] install.sh: \(line)")
        }
    }

    func addToPaths() throws {
        // `/etc/paths.d` is root's alone, so a plain atomic write is safe.
        try Data("\(Self.prefix)/bin\n".utf8).write(to: URL(fileURLWithPath: Self.pathsFile), options: .atomic)
        guard chmod(Self.pathsFile, 0o644) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func brewVersion(as user: String) async throws -> String? {
        guard let context = UserContext(username: user)?.prependingPath("\(Self.prefix)/bin") else {
            throw HomebrewError.unknownOwner(user)
        }
        let result = try await ProcessRunner.capture(Self.brew, arguments: ["--version"], as: context, timeout: .seconds(2 * 60))
        guard result.isSuccess else { return nil }
        return result.standardOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    // MARK: - Private

    /// `lstat`: `path` itself, never what it links to. `nil` when there's nothing there.
    private static func entry(_ path: String) throws -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info
    }

    /// `getpwnam_r`: the daemon looks users up from several tasks at once.
    private static func account(named name: String) -> uid_t? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwnam_r(name, &entry, &buffer, buffer.count, &result) == 0, result != nil else { return nil }
        return entry.pw_uid
    }

    /// The account's short name, or `#<uid>` when it has none: never equal to a declared owner.
    private static func userName(_ uid: uid_t) -> String {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil, let name = entry.pw_name else {
            return "#\(uid)"
        }
        return String(cString: name)
    }
}
