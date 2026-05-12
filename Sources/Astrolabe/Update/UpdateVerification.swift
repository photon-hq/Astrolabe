import Foundation

/// How to verify a downloaded `.pkg` before installing it.
///
/// Default is `.pkgSignatureRequired` — refuse any pkg whose Apple-signed
/// signature does not pass `pkgutil --check-signature`. This blocks
/// supply-chain swaps unless explicitly opted out via `.none`.
public enum UpdateVerification: Sendable {
    /// Skip verification. Only appropriate for local development.
    case none

    /// Require the pkg to be signed (any valid Developer ID Installer signature).
    /// Default for `UpdateConfiguration`.
    case pkgSignatureRequired

    /// Require the pkg to be signed AND the Team ID inside the certificate
    /// to match the supplied string exactly. Strongest binding — defeats
    /// substitution by any other signed package.
    case codesignTeamID(String)
}

/// Errors raised by `UpdateVerificationRunner`.
public enum UpdateVerificationError: Error, Sendable, CustomStringConvertible {
    case signatureCheckFailed(output: String)
    case teamIDMismatch(expected: String, actual: String?)

    public var description: String {
        switch self {
        case .signatureCheckFailed(let output):
            return "pkg signature check failed: \(output)"
        case .teamIDMismatch(let expected, let actual):
            return "pkg signed by Team ID \(actual ?? "<unknown>") — expected \(expected)"
        }
    }
}

/// Executes the verification policy described by an `UpdateVerification`.
enum UpdateVerificationRunner {

    /// Verifies `pkgPath` according to `policy`. Throws on failure.
    static func verify(_ policy: UpdateVerification, pkgPath: URL) async throws {
        switch policy {
        case .none:
            return

        case .pkgSignatureRequired:
            let result = runPkgutilCheckSignature(at: pkgPath)
            guard result.exitCode == 0 else {
                throw UpdateVerificationError.signatureCheckFailed(output: result.output)
            }

        case .codesignTeamID(let expected):
            let result = runPkgutilCheckSignature(at: pkgPath)
            guard result.exitCode == 0 else {
                throw UpdateVerificationError.signatureCheckFailed(output: result.output)
            }
            let actual = extractTeamID(from: result.output)
            guard actual == expected else {
                throw UpdateVerificationError.teamIDMismatch(expected: expected, actual: actual)
            }
        }
    }

    // MARK: - Internal

    private static func runPkgutilCheckSignature(at pkgPath: URL) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--check-signature", pkgPath.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Parses the Team ID from `pkgutil --check-signature` output.
    /// pkgutil prints the cert chain like:
    ///     1. Developer ID Installer: Acme Inc. (ABCD1234)
    /// We grab the parenthesized 10-char identifier on the first signing cert line.
    static func extractTeamID(from output: String) -> String? {
        // Find `(XXXXXXXXXX)` where the contents are 10 alphanumeric chars,
        // following a "Developer ID Installer" or similar signing identity line.
        let pattern = #"\(([A-Z0-9]{10})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: output)
        else { return nil }
        return String(output[captured])
    }
}
