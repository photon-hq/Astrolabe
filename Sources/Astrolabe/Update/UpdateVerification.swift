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
            let result = await runPkgutilCheckSignature(at: pkgPath)
            guard result.exitCode == 0 else {
                throw UpdateVerificationError.signatureCheckFailed(output: result.output)
            }

        case .codesignTeamID(let expected):
            let result = await runPkgutilCheckSignature(at: pkgPath)
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

    /// The cert chain is parsed out of this output, so it keeps the merged view: pkgutil
    /// splits the chain and its warnings across both streams.
    private static func runPkgutilCheckSignature(at pkgPath: URL) async -> (exitCode: Int32, output: String) {
        guard let result = try? await ProcessRunner.capture(
            "/usr/sbin/pkgutil",
            arguments: ["--check-signature", pkgPath.path]
        ) else {
            return (-1, "pkgutil --check-signature could not be run")
        }
        return (result.exitCode, result.combined)
    }

    /// Parses the Team ID from `pkgutil --check-signature` output.
    /// pkgutil prints the cert chain like:
    ///     1. Developer ID Installer: Acme Inc. (ABCD123456)
    /// We extract the parenthesized 10-char identifier ONLY when it appears on
    /// a line whose signer identity is "Developer ID Installer" or
    /// "Developer ID Application" — otherwise a stray 10-char token elsewhere
    /// in the output (a filename, description, etc.) could spoof the match.
    static func extractTeamID(from output: String) -> String? {
        // `.` doesn't match `\n` by default in NSRegularExpression, so the
        // match is naturally constrained to a single line. `[^\n]` is used
        // explicitly to make that intent unmistakable.
        let pattern = #"Developer ID (?:Installer|Application)[^\n]*?\(([A-Z0-9]{10})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: output)
        else { return nil }
        return String(output[captured])
    }
}
