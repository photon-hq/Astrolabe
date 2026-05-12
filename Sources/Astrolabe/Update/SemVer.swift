import Foundation

/// A minimal SemVer 2.0.0 parser and comparator for the self-updater.
///
/// Accepts `MAJOR.MINOR.PATCH` with an optional `-PRERELEASE` suffix
/// (e.g. `1.2.3`, `1.2.3-beta.1`). A leading `v` is stripped.
/// Build metadata after `+` is ignored for ordering, per SemVer §10.
///
/// Ordering follows SemVer §11: numeric components compare numerically,
/// a release (no prerelease) sorts higher than any prerelease of the same
/// MAJOR.MINOR.PATCH, and prerelease identifiers compare dot-separated.
public struct SemVer: Sendable, Comparable, CustomStringConvertible, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `nil` means this is a release version. Non-`nil` means prerelease,
    /// e.g. `"beta.1"`. Always sorts lower than `nil` for the same M.m.p.
    public let preRelease: String?

    public init(major: Int, minor: Int, patch: Int, preRelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// Parses a SemVer string. Returns `nil` if the string is malformed.
    public init?(_ string: String) {
        var s = string
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }

        // Strip build metadata (everything after `+`).
        if let plus = s.firstIndex(of: "+") {
            s = String(s[..<plus])
        }

        // Split on first `-` to separate version from prerelease.
        var versionPart = s
        var preRelease: String? = nil
        if let dash = s.firstIndex(of: "-") {
            versionPart = String(s[..<dash])
            preRelease = String(s[s.index(after: dash)...])
            if preRelease?.isEmpty == true { return nil }
        }

        let parts = versionPart.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return preRelease.map { "\(core)-\($0)" } ?? core
    }

    // MARK: - Comparable

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // §11.3: release > any prerelease of the same M.m.p
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil): return false
        case (nil, _?):  return false      // lhs is release, rhs is prerelease → lhs > rhs
        case (_?, nil):  return true       // lhs is prerelease, rhs is release → lhs < rhs
        case (let l?, let r?):
            return comparePreRelease(l, r) < 0
        }
    }

    /// Compares two prerelease strings per SemVer §11.4. Returns negative if
    /// `lhs < rhs`, zero if equal, positive if `lhs > rhs`.
    private static func comparePreRelease(_ lhs: String, _ rhs: String) -> Int {
        let ls = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let rs = rhs.split(separator: ".", omittingEmptySubsequences: false)

        for i in 0 ..< min(ls.count, rs.count) {
            let a = String(ls[i])
            let b = String(rs[i])
            let aNum = Int(a)
            let bNum = Int(b)

            switch (aNum, bNum) {
            case (let an?, let bn?):
                if an != bn { return an < bn ? -1 : 1 }
            case (_?, nil):
                // numeric identifiers sort lower than alphanumeric (§11.4.3)
                return -1
            case (nil, _?):
                return 1
            case (nil, nil):
                if a != b { return a < b ? -1 : 1 }
            }
        }
        if ls.count != rs.count {
            return ls.count < rs.count ? -1 : 1
        }
        return 0
    }
}
