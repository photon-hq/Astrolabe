/// A version as Homebrew names a Cellar/Caskroom directory.
///
/// `SemVer` can't read these: it requires exactly three numeric parts, while kegs are named
/// `1.104.1_1` (a formula revision), `3.0`, `2024.08.2`, or `1.2.3,456` (a cask's version
/// plus build). Numeric parts are compared left to right, the shorter one padded with zeros,
/// so `1.102 == 1.102.0`. A formula revision (`_1`) breaks ties. Anything non-numeric, such
/// as a `HEAD-…` keg or a cask's `latest`, fails to parse.
struct BrewVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]
    let revision: Int
    let description: String

    init?(_ string: String) {
        var base = Substring(string)
        var revision = 0
        if let underscore = base.lastIndex(of: "_") {
            guard let parsed = Self.number(base[base.index(after: underscore)...]) else { return nil }
            revision = parsed
            base = base[..<underscore]
        }
        var parts: [Int] = []
        for part in base.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," }) {
            guard let number = Self.number(part) else { return nil }
            parts.append(number)
        }
        self.parts = parts
        self.revision = revision
        self.description = string
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let (l, r) = padded(lhs, rhs)
        return l != r ? l.lexicographicallyPrecedes(r) : lhs.revision < rhs.revision
    }

    /// Consistent with `<`: `1.102` and `1.102.0` are the same version.
    static func == (lhs: Self, rhs: Self) -> Bool {
        let (l, r) = padded(lhs, rhs)
        return l == r && lhs.revision == rhs.revision
    }

    private static func padded(_ lhs: Self, _ rhs: Self) -> ([Int], [Int]) {
        let width = max(lhs.parts.count, rhs.parts.count)
        return (
            lhs.parts + Array(repeating: 0, count: width - lhs.parts.count),
            rhs.parts + Array(repeating: 0, count: width - rhs.parts.count)
        )
    }

    /// Digits only: `Int.init` would also accept `+1` and `-1`.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}
