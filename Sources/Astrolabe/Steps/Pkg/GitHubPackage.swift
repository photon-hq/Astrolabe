import Foundation

/// Installs a `.pkg` from a GitHub release.
///
/// ```swift
/// PackageInstaller(.gitHub("owner/repo"))
/// PackageInstaller(.gitHub("owner/repo", version: .tag("v1.0.0")))
/// ```
public struct GitHubPackage: PackageProvider {
    public enum Version: Sendable, Equatable {
        case latest
        case tag(String)
    }

    /// How to match an asset filename in the release.
    public enum AssetFilter: Sendable {
        /// Matches the first asset ending in `.pkg`.
        case pkg
        /// Matches an exact filename.
        case filename(String)
        /// Matches filenames against a regex pattern.
        case regex(String)
    }

    /// How to determine whether the package is already installed.
    public enum InstallCheck: Sendable {
        /// Check for a binary matching the repo name (default).
        case binary
        /// Check for a specific binary name.
        case binaryName(String)
        /// Check that all listed binaries exist.
        case binaries([String])
        /// Fully custom check.
        case custom(@Sendable () async -> Bool)
    }

    public let repo: String
    public let version: Version
    public let asset: AssetFilter
    public let installCheck: InstallCheck

    public var id: String { repo }

    public init(repo: String, version: Version = .latest, asset: AssetFilter = .pkg, installCheck: InstallCheck = .binary) {
        self.repo = repo
        self.version = version
        self.asset = asset
        self.installCheck = installCheck
    }

    public func isInstalled() async -> Bool {
        switch installCheck {
        case .binary:
            let binary = repo.split(separator: "/").last.map(String.init) ?? repo
            return await Self.binaryExists(binary)
        case .binaryName(let name):
            return await Self.binaryExists(name)
        case .binaries(let names):
            for name in names {
                guard await Self.binaryExists(name) else { return false }
            }
            return true
        case .custom(let check):
            return await check()
        }
    }

    /// Walks `PATH` on the filesystem — no `which` process is spawned.
    private static func binaryExists(_ name: String) async -> Bool {
        await ProcessRunner.commandExists(name)
    }

    public var payloadRecord: PayloadRecord? { .pkg(id: repo, files: []) }

    public func install() async throws {
        print("[Astrolabe] Fetching release for \(repo)...")

        let token = EnvironmentValues.current.githubToken
        let release: GitHubRelease
        do {
            release = switch version {
            case .latest: try await GitHubReleaseFetcher.fetchLatest(repo: repo, token: token)
            case .tag(let tag): try await GitHubReleaseFetcher.fetchByTag(repo: repo, tag: tag, token: token)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GitHubError.releaseNotFound(repo: repo, version: version)
        }

        guard let asset = GitHubReleaseFetcher.selectAsset(in: release, filter: self.asset) else {
            throw GitHubError.noMatchingAsset(repo: repo, tag: release.tagName, filter: self.asset)
        }

        print("[Astrolabe] Downloading \(asset.name)...")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrolabe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pkgPath = tempDir.appendingPathComponent(asset.name)
        let request = GitHubReleaseFetcher.makeAssetDownloadRequest(asset: asset, token: token)
        let (downloadURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubFetchError.requestFailed(repo: repo, statusCode: http.statusCode)
        }
        try FileManager.default.moveItem(at: downloadURL, to: pkgPath)

        print("[Astrolabe] Installing \(asset.name)...")

        var arguments = ["-pkg", pkgPath.path, "-target", "/"]
        if EnvironmentValues.current.allowUntrusted {
            arguments.insert("-allowUntrusted", at: 0)
        }

        // Streamed: `installer` runs the package's own scripts, which can be arbitrarily
        // chatty, and the old drain-after-wait would deadlock once they filled the pipe.
        do {
            try await ProcessRunner.stream("/usr/sbin/installer", arguments: arguments) { line in
                print("[Astrolabe] installer: \(line)")
            }
        } catch let error as ReconcileError {
            guard case .processFailed(_, _, let output) = error else { throw error }
            throw GitHubError.installFailed(package: asset.name, output: output)
        }

        print("[Astrolabe] Installed \(asset.name) successfully.")
    }
}

// MARK: - Errors

public enum GitHubError: Error, Sendable {
    case releaseNotFound(repo: String, version: GitHubPackage.Version)
    case noMatchingAsset(repo: String, tag: String, filter: GitHubPackage.AssetFilter)
    case installFailed(package: String, output: String)
}

// MARK: - Dot Syntax

extension PackageProvider where Self == GitHubPackage {
    /// A package from a GitHub release.
    public static func gitHub(
        _ repo: String,
        version: GitHubPackage.Version = .latest,
        asset: GitHubPackage.AssetFilter = .pkg,
        installCheck: GitHubPackage.InstallCheck = .binary
    ) -> GitHubPackage {
        GitHubPackage(repo: repo, version: version, asset: asset, installCheck: installCheck)
    }
}
