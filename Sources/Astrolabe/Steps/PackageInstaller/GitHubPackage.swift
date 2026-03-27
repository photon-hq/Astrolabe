import Foundation

/// Installs a `.pkg` from a GitHub release.
///
/// ```swift
/// Package(.gitHub("owner/repo"))
/// Package(.gitHub("owner/repo", version: .tag("v1.0.0")))
/// ```
public struct GitHubPackage: PackageProvider {
    public enum Version: Sendable, Equatable {
        case latest
        case tag(String)
    }

    public let repo: String
    public let version: Version

    public init(repo: String, version: Version = .latest) {
        self.repo = repo
        self.version = version
    }

    public func install() async throws {
        // TODO: Implement
        // 1. GET /repos/{owner}/{repo}/releases/latest (or /tags/{tag})
        // 2. Find asset with .pkg extension
        // 3. Download to temp directory
        // 4. Run: installer -pkg <path> -target /
        print("[Astrolabe] Installing \(repo) from GitHub (\(version))...")
    }
}

extension PackageProvider where Self == GitHubPackage {
    /// A package from a GitHub release.
    ///
    /// - Parameters:
    ///   - repo: Repository in `"owner/repo"` format.
    ///   - version: Which release to fetch. Defaults to `.latest`.
    public static func gitHub(_ repo: String, version: GitHubPackage.Version = .latest) -> GitHubPackage {
        GitHubPackage(repo: repo, version: version)
    }
}
