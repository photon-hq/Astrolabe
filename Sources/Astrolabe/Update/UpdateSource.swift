import Foundation

/// A source of update releases. Implementations fetch release metadata
/// from somewhere (GitHub, GitLab, S3, a private manifest URL) and tell the
/// updater what the newest available release looks like.
///
/// Ships with `GitHubReleaseSource`. Conform to add custom sources:
///
/// ```swift
/// struct MyPrivateSource: UpdateSource {
///     func latestRelease(channel: UpdateConfiguration.Channel) async throws -> ReleaseDescriptor? {
///         // ... your fetch logic ...
///     }
/// }
/// ```
public protocol UpdateSource: Sendable {
    /// Returns the newest release available on the given channel, or `nil` if
    /// the source has no matching release. Throwing signals a transient failure
    /// (network error, rate limit, bad JSON); the updater will retry next tick.
    func latestRelease(channel: UpdateConfiguration.Channel) async throws -> ReleaseDescriptor?
}

/// A normalized description of an update release.
public struct ReleaseDescriptor: Sendable {
    /// SemVer string, e.g. `"1.2.3"` or `"1.2.3-beta.1"`. Used for version comparison.
    public let version: String
    /// Raw tag from the source, e.g. `"v1.2.3"`. Surfaced for logging/observability.
    public let tag: String
    /// Direct download URL for the artifact (`.pkg` in v1).
    public let downloadURL: URL
    /// HTTP headers to include when downloading the artifact.
    public let downloadHeaders: [String: String]
    /// Filename of the artifact, used as the local download name.
    public let assetName: String

    public init(
        version: String,
        tag: String,
        downloadURL: URL,
        assetName: String,
        downloadHeaders: [String: String] = [:]
    ) {
        self.version = version
        self.tag = tag
        self.downloadURL = downloadURL
        self.downloadHeaders = downloadHeaders
        self.assetName = assetName
    }

    public func makeDownloadRequest() -> URLRequest {
        var request = URLRequest(url: downloadURL)
        for (field, value) in downloadHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

// MARK: - Dot syntax

extension UpdateSource where Self == GitHubReleaseSource {
    /// An update source backed by a GitHub repository's releases.
    ///
    /// - Parameter repo: `"owner/name"` (e.g. `"acme/mysetup"`).
    /// - Parameter version: `.latest` to track the channel's newest, or
    ///   `.tag("v1.2.3")` to pin to a specific tag.
    /// - Parameter asset: How to pick the artifact from the release's
    ///   asset list. Default `.pkg` matches the first `.pkg` asset.
    public static func gitHub(
        _ repo: String,
        version: GitHubReleaseSource.Pin = .latest,
        asset: GitHubPackage.AssetFilter = .pkg
    ) -> GitHubReleaseSource {
        GitHubReleaseSource(repo: repo, pin: version, asset: asset)
    }
}
