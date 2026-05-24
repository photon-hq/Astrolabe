import Foundation

/// An `UpdateSource` backed by GitHub Releases.
///
/// Reads the GitHub API token from `ProcessInfo.processInfo.environment["GITHUB_TOKEN"]`.
/// The token is injected into the updater daemon's plist `EnvironmentVariables` by
/// `UpdaterDaemonManager` when `UpdateConfiguration.githubToken` is set.
public struct GitHubReleaseSource: UpdateSource {
    /// Which release on the repo to consider.
    public enum Pin: Sendable, Equatable {
        /// Track whichever release the channel surfaces as newest.
        case latest
        /// Pin to one exact tag. The updater installs that tag once if newer
        /// than the current binary, then no-ops forever.
        case tag(String)
    }

    public let repo: String
    public let pin: Pin
    public let asset: GitHubPackage.AssetFilter

    public init(repo: String, pin: Pin = .latest, asset: GitHubPackage.AssetFilter = .pkg) {
        self.repo = repo
        self.pin = pin
        self.asset = asset
    }

    public func latestRelease(channel: UpdateConfiguration.Channel) async throws -> ReleaseDescriptor? {
        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]

        let release: GitHubRelease
        switch pin {
        case .tag(let tag):
            // Pinned: ignore channel — fetch the exact tag.
            release = try await GitHubReleaseFetcher.fetchByTag(repo: repo, tag: tag, token: token)

        case .latest:
            switch channel {
            case .stable:
                release = try await GitHubReleaseFetcher.fetchLatest(repo: repo, token: token)
            case .prerelease:
                // Newest non-draft release (which may or may not be flagged prerelease).
                let recent = try await GitHubReleaseFetcher.fetchRecent(repo: repo, perPage: 10, token: token)
                guard let newest = recent.first else { return nil }
                release = newest
            }
        }

        guard let asset = GitHubReleaseFetcher.selectAsset(in: release, filter: self.asset) else {
            return nil
        }

        // SemVer string is the tag with a leading "v" stripped.
        let versionString = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName

        let downloadRequest = GitHubReleaseFetcher.makeAssetDownloadRequest(asset: asset, token: token)

        return ReleaseDescriptor(
            version: versionString,
            tag: release.tagName,
            downloadURL: downloadRequest.url ?? asset.downloadURL,
            assetName: asset.name,
            downloadHeaders: downloadRequest.allHTTPHeaderFields ?? [:]
        )
    }
}
