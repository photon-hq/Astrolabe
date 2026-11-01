import Darwin
import Foundation

/// A Command Line Tools version as major.minor.patch.
///
/// The receipt's `26.4.1.0.1.1745106510`, the catalog's `26.4.1`, and `16.4` (= `16.4.0`) all
/// normalize here, so a hash never depends on where a version came from. Encoded as its
/// `description`, so `records.json` reads `"26.4.1"`.
public struct CLTVersion: Comparable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The first three dot-separated parts, digits only; missing parts are 0. `nil` otherwise.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts.prefix(3) {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = CLTVersion(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a CLT version: \(string)")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A Command Line Tools product in `softwareupdate --list`.
struct CLTProduct: Equatable, Sendable {
    /// Passed verbatim to `softwareupdate --install`.
    let label: String
    let version: CLTVersion
}

/// Reads `softwareupdate --list` output.
///
/// Versions come from the `Version:` field, never the label: labels changed format on macOS 26.
///
/// ```
/// * Label: Command Line Tools for Xcode-16.4                      ← macOS 15
/// 	Title: Command Line Tools for Xcode, Version: 16.4, Size: 751282KiB, Recommended: YES,
/// * Label: Command Line Tools for Xcode 26.4-26.4.1               ← macOS 26
/// 	Title: Command Line Tools for Xcode 26.4, Version: 26.4.1, Size: 920104KiB, Recommended: YES,
/// ```
enum SoftwareUpdateListing {
    /// CLT products in `softwareupdate --list` output (stdout + stderr), betas excluded.
    static func commandLineTools(in listing: String) -> [CLTProduct] {
        var products: [CLTProduct] = []
        var label: String?
        for line in listing.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("* Label: ") {
                label = String(line.dropFirst("* Label: ".count))
            } else if let current = label, line.hasPrefix("Title: ") {
                label = nil
                let fields = fields(line)
                guard current.hasPrefix("Command Line Tools"),
                      !current.localizedCaseInsensitiveContains("beta"),
                      !(fields["Title"]?.localizedCaseInsensitiveContains("beta") ?? false),
                      let version = fields["Version"].flatMap(CLTVersion.init)
                else { continue }
                products.append(CLTProduct(label: current, version: version))
            }
        }
        return products
    }

    /// `Title: a, Version: b, …` → `["Title": "a", "Version": "b", …]`. The first of a key wins.
    private static func fields(_ line: String) -> [String: String] {
        var fields: [String: String] = [:]
        for field in line.split(separator: ",") {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].trimmingCharacters(in: .whitespaces)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }
}

/// Everything Command Line Tools does on the Mac. Tests bind a fake through
/// `CommandLineToolsContext`, so they never run `softwareupdate` or touch the trigger file.
protocol CommandLineToolsSystem: Sendable {
    /// From `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`. `nil` when there's no receipt
    /// ("No receipt for …") or `/Library/Developer/CommandLineTools/usr/bin/git` is missing. Any
    /// other pkgutil failure throws, so a hiccup never reads as "not installed".
    func installedVersion() async throws -> CLTVersion?

    /// When a CLTools receipt exists but `usr/bin/git` doesn't (deleted by hand), runs
    /// `pkgutil --forget` on each `com.apple.pkg.CLTools_*` receipt so softwareupdate offers CLT
    /// again. Otherwise does nothing.
    func forgetStaleReceipts() async throws

    /// Creates `/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress`.
    func placeTrigger() throws

    /// Removes the trigger file, if it's there.
    func removeTrigger()

    /// `softwareupdate --list`, parsed. Throws on a non-zero exit.
    func list() async throws -> [CLTProduct]

    /// `softwareupdate --install <label> --agree-to-license --verbose`, streamed.
    func install(_ product: CLTProduct) async throws

    /// `xcode-select --switch /Library/Developer/CommandLineTools`, only when `xcode-select -p`
    /// fails or points at a missing path. A valid Xcode.app selection is left alone.
    func ensureSelected() async throws
}

/// The real `CommandLineToolsSystem`.
struct SoftwareUpdateCLT: CommandLineToolsSystem {
    static let directory = "/Library/Developer/CommandLineTools"
    static let git = "\(directory)/usr/bin/git"
    static let executablesReceipt = "com.apple.pkg.CLTools_Executables"
    static let receiptPrefix = "com.apple.pkg.CLTools_"
    /// `softwareupdate` lists and installs CLT only while this file exists.
    static let trigger = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

    private static let pkgutil = "/usr/sbin/pkgutil"
    private static let softwareupdate = "/usr/sbin/softwareupdate"
    private static let xcodeSelect = "/usr/bin/xcode-select"

    func installedVersion() async throws -> CLTVersion? {
        guard FileManager.default.fileExists(atPath: Self.git) else { return nil }
        let result = try await ProcessRunner.capture(Self.pkgutil, arguments: ["--pkg-info=\(Self.executablesReceipt)"])
        if !result.isSuccess, result.combined.contains("No receipt for") { return nil }
        guard result.isSuccess else { throw result.failure }
        guard let version = Self.receiptVersion(in: result.standardOutput) else {
            throw CLTError.unreadableReceipt(output: result.combined)
        }
        return version
    }

    /// The `version:` line of `pkgutil --pkg-info` output.
    static func receiptVersion(in pkgInfo: String) -> CLTVersion? {
        pkgInfo.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("version: ") }
            .flatMap { CLTVersion(String($0.dropFirst("version: ".count))) }
    }

    func forgetStaleReceipts() async throws {
        guard !FileManager.default.fileExists(atPath: Self.git) else { return }
        let receipts = try await ProcessRunner.run(Self.pkgutil, arguments: ["--pkgs"], timeout: ProcessRunner.Timeout.probe)
            .standardOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(Self.receiptPrefix) }
        for receipt in receipts {
            print("[Astrolabe] forgetting stale receipt \(receipt): \(Self.git) is missing")
            try await ProcessRunner.run(Self.pkgutil, arguments: ["--forget", receipt])
        }
    }

    /// Never follows a symlink: the daemon is root, and `/tmp` is anyone's.
    func placeTrigger() throws {
        var info = stat()
        if lstat(Self.trigger, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            unlink(Self.trigger)
        }
        let fd = open(Self.trigger, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
    }

    func removeTrigger() {
        unlink(Self.trigger)
    }

    func list() async throws -> [CLTProduct] {
        // The listing lands on stderr on some macOS versions: parse both streams.
        let result = try await ProcessRunner.run(Self.softwareupdate, arguments: ["--list"], timeout: .seconds(5 * 60))
        return SoftwareUpdateListing.commandLineTools(in: result.combined)
    }

    func install(_ product: CLTProduct) async throws {
        print("[Astrolabe] installing \(product.label) (\(product.version))")
        try await ProcessRunner.stream(
            Self.softwareupdate,
            arguments: ["--install", product.label, "--agree-to-license", "--verbose"],
            timeout: ProcessRunner.Timeout.install
        ) { line in
            print("[Astrolabe] softwareupdate: \(line)")
        }
    }

    func ensureSelected() async throws {
        let result = try await ProcessRunner.capture(Self.xcodeSelect, arguments: ["-p"])
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isSuccess, !path.isEmpty, FileManager.default.fileExists(atPath: path) { return }
        try await ProcessRunner.run(Self.xcodeSelect, arguments: ["--switch", Self.directory])
    }
}
