import Foundation

/// Shared GitHub Releases API client. Used by both `GitHubPackage` (for `Pkg(.gitHub(...))`)
/// and `GitHubReleaseSource` (for the self-updater).
///
/// No state of its own — just typed wrappers over `URLSession.shared` against
/// `api.github.com`.
enum GitHubReleaseFetcher {

    // MARK: - Fetch

    /// Fetches the release marked `latest` for the repo (skipping prereleases and drafts).
    static func fetchLatest(repo: String, token: String?) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        return try await fetchOne(url: url, repo: repo, token: token)
    }

    /// Fetches the release with the given tag.
    static func fetchByTag(repo: String, tag: String, token: String?) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)")!
        return try await fetchOne(url: url, repo: repo, token: token)
    }

    /// Fetches the most recent releases (newest first), skipping drafts.
    /// `perPage` is clamped to 1...100 per GitHub's API limits.
    static func fetchRecent(repo: String, perPage: Int = 10, token: String?) async throws -> [GitHubRelease] {
        let clamped = max(1, min(100, perPage))
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(clamped)")!
        let request = makeRequest(url: url, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GitHubFetchError.requestFailed(repo: repo, statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases.filter { !$0.draft }
    }

    // MARK: - Asset selection

    /// Returns the first asset in `release` matching `filter`, or `nil`.
    static func selectAsset(in release: GitHubRelease, filter: GitHubPackage.AssetFilter) -> GitHubAsset? {
        switch filter {
        case .pkg:
            return release.assets.first { $0.name.hasSuffix(".pkg") }
        case .filename(let name):
            return release.assets.first { $0.name == name }
        case .regex(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return release.assets.first { asset in
                let range = NSRange(asset.name.startIndex..., in: asset.name)
                return regex.firstMatch(in: asset.name, range: range) != nil
            }
        }
    }

    // MARK: - Internal helpers

    private static func fetchOne(url: URL, repo: String, token: String?) async throws -> GitHubRelease {
        let request = makeRequest(url: url, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GitHubFetchError.requestFailed(repo: repo, statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    static func makeRequest(url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Wire models

/// A GitHub release as returned by the Releases API. Includes the fields we care about.
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let assets: [GitHubAsset]
    let prerelease: Bool
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case prerelease
        case draft
    }
}

struct GitHubAsset: Decodable, Sendable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

// MARK: - Fetcher errors

/// Errors raised by `GitHubReleaseFetcher`. `GitHubPackage` may wrap these
/// into its own `GitHubError` cases for backwards compatibility.
public enum GitHubFetchError: Error, Sendable, CustomStringConvertible {
    case requestFailed(repo: String, statusCode: Int)

    public var description: String {
        switch self {
        case .requestFailed(let repo, let code):
            return "GitHub API request failed for \(repo) (status \(code))"
        }
    }
}
