import Darwin
import Foundation

extension InstallScriptHomebrew {
    func packages() throws -> BrewPackages {
        try BrewScan.packages(prefix: Self.prefix)
    }

    func brew(_ arguments: [String], as user: String) async throws {
        guard let context = UserContext(username: user)?.prependingPath("\(Self.prefix)/bin") else {
            throw HomebrewError.unknownOwner(user)
        }
        print("[Astrolabe] brew \(arguments.joined(separator: " ")) as \(user)")
        try await ProcessRunner.stream(Self.brew, arguments: arguments, as: context, timeout: ProcessRunner.Timeout.install) { line in
            print("[Astrolabe] brew: \(line)")
        }
    }
}

/// Reads what Homebrew has installed from its prefix: `readdir` and `readlink`, never `brew`.
///
/// Installed means what `brew list <name>` means: at least one non-empty version directory. An
/// interrupted uninstall leaves an empty `Cellar/<name>` behind, and a cask's `.metadata`
/// outlives its uninstall. Neither counts.
enum BrewScan {
    /// Every formula in `<prefix>/Cellar` and cask in `<prefix>/Caskroom`.
    ///
    /// A missing `Cellar` or `Caskroom` reads as empty. Below them, dot-names and anything that
    /// isn't a directory are skipped, and an entry that vanishes mid-scan (`brew cleanup`) is
    /// not there. Any other error throws, so a hiccup never reads as "nothing installed".
    static func packages(prefix: String) throws -> BrewPackages {
        var packages = BrewPackages()
        for (name, kegs) in try installed(in: "\(prefix)/Cellar") {
            packages.formulae[name] = try linked(kegs, at: "\(prefix)/opt/\(name)") ?? current(kegs)
        }
        for (name, kegs) in try installed(in: "\(prefix)/Caskroom") {
            packages.casks[name] = current(kegs)
        }
        return packages
    }

    /// Each package in `root` with its non-empty version directories. Packages with none are
    /// left out.
    private static func installed(in root: String) throws -> [String: [String]] {
        var packages: [String: [String]] = [:]
        for name in try names(in: root) ?? [] where !name.hasPrefix(".") {
            var kegs: [String] = []
            for version in try names(in: "\(root)/\(name)") ?? [] where !version.hasPrefix(".") {
                if let contents = try names(in: "\(root)/\(name)/\(version)"), !contents.isEmpty {
                    kegs.append(version)
                }
            }
            if !kegs.isEmpty { packages[name] = kegs }
        }
        return packages
    }

    /// The keg `link` points at (`opt/<name>`, what `brew` runs), when it's one of `kegs`.
    private static func linked(_ kegs: [String], at link: String) throws -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(link, &buffer, buffer.count - 1)
        guard length >= 0 else {
            let error = errno
            // No link, or not a link: fall back to the highest keg.
            if error == ENOENT || error == ENOTDIR || error == EINVAL { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        let target = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let keg = target.split(separator: "/").last.map(String.init), kegs.contains(keg) else { return nil }
        return keg
    }

    /// The highest version that parses, or the first name when none does (`HEAD-…`, `latest`),
    /// so a check can report it.
    private static func current(_ kegs: [String]) -> String? {
        let parsed = kegs.compactMap { keg in BrewVersion(keg).map { (keg, $0) } }
        if let highest = parsed.max(by: { $0.1 < $1.1 }) { return highest.0 }
        return kegs.sorted().first
    }

    /// The names in `directory`, without `.` and `..`. `nil` when there's no directory there:
    /// missing, or a file.
    private static func names(in directory: String) throws -> [String]? {
        guard let handle = opendir(directory) else {
            let error = errno
            if error == ENOENT || error == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        defer { closedir(handle) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                let error = errno
                guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }
}
