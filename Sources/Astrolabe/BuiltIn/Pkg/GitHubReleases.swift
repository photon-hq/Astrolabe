import Foundation

/// The GitHub Releases API: what `Pkg(.gitHub(…))` installs from, and what `tag: .latest`
/// checks.
///
/// `latestTag` is public for apps that want a repo's newest tag in a fact of their own, e.g. to
/// gate other components on it:
///
/// ```swift
/// extension Facts {
///     /// Hourly. A failed read keeps the last tag.
///     @FactEntry(schedule: .every(.seconds(3600)), read: {
///         try await GitHubReleases.latestTag("org/tool")
///     })
///     var toolTag: String?
/// }
/// ```
///
/// To install the newest release, declare `Pkg(.gitHub("org/tool", tag: .latest))` instead.
public enum GitHubReleases {
    /// How `latestTag` ranks the releases it keeps.
    public enum Order: String, Codable, Sendable, Hashable {
        /// Newest published first.
        case published
        /// Highest version first: the tag, a leading `v` stripped, compared as numbers
        /// (`v2.10` above `v2.9`). Tags that don't parse (`v2.0-beta`, `nightly`) sort last.
        case version
    }

    /// The tag of `repo`'s newest release.
    ///
    /// With no options, GitHub's own "Latest" release (`/releases/latest`): never a draft or a
    /// prerelease. With any option, the 30 most recent releases, without drafts, then:
    ///
    /// - `prereleases`: keep prereleases too.
    /// - `tag`: keep tags matching this regex, e.g. `^v2\.` to stay on one major line.
    /// - `asset`: keep releases with an asset that matches, e.g. ones that ship a `.pkg` yet.
    /// - `order`: rank by publication (the default) or by version.
    ///
    /// Throws when nothing matches, or the request fails: never returns a guess. In a fact's
    /// `read`, a throw keeps the last tag.
    public static func latestTag(
        _ repo: String,
        token: GitHubToken? = nil,
        prereleases: Bool = false,
        tag: String? = nil,
        asset: GitHubAsset.Filter? = nil,
        order: Order = .published
    ) async throws -> String {
        let token = try token?.resolve()
        let options = Options(prereleases: prereleases, tag: tag, asset: asset, order: order)
        if options.isDefault {
            return try await fetchLatest(repo: repo, token: token).tagName
        }
        return try latestTag(of: repo, in: try await fetchRecent(repo: repo, perPage: 30, token: token), options)
    }

    /// What `latestTag` filters and ranks by.
    struct Options: Codable, Sendable, Hashable {
        var prereleases = false
        var tag: String?
        var asset: GitHubAsset.Filter?
        var order: Order = .published

        /// No option set: `/releases/latest` answers.
        var isDefault: Bool { !prereleases && tag == nil && asset == nil && order == .published }
    }

    /// `select`'s tag, or `noMatchingRelease`.
    static func latestTag(of repo: String, in releases: [GitHubRelease], _ options: Options) throws -> String {
        guard let release = try select(releases, options) else { throw GitHubReleasesError.noMatchingRelease(repo: repo) }
        return release.tagName
    }

    /// Pure: the release `latestTag` picks from `releases`, or `nil` when none is kept. Throws only
    /// on a `tag` or `asset` pattern that isn't a regex.
    static func select(_ releases: [GitHubRelease], _ options: Options) throws -> GitHubRelease? {
        let tagPattern = try options.tag.map(regex)
        if case .regex(let pattern) = options.asset { _ = try regex(pattern) }
        let kept = releases.filter { release in
            guard !release.draft, options.prereleases || !release.prerelease else { return false }
            if let tagPattern, !matches(tagPattern, release.tagName) { return false }
            if let asset = options.asset, selectAsset(in: release, filter: asset) == nil { return false }
            return true
        }
        let published = newestFirst(kept)
        switch options.order {
        case .published:
            return published.first
        case .version:
            // Highest parseable version; ties and unparseable tags keep publication order.
            let parsed = published.compactMap { release in version(of: release.tagName).map { (release, $0) } }
            if let highest = parsed.max(by: { $0.1 < $1.1 }) {
                return parsed.first { $0.1 == highest.1 }?.0
            }
            return published.first
        }
    }

    /// `v1.2.3` and `1.2.3` alike. `nil` for anything `BrewVersion` can't read.
    static func version(of tag: String) -> BrewVersion? {
        BrewVersion(tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag)
    }

    // MARK: - Fetch

    /// Every request runs under `PkgContext.lock` or in a fact read: a stalled one must end.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// GitHub's "Latest" release: never a draft or a prerelease.
    static func fetchLatest(repo: String, token: String?) async throws -> GitHubRelease {
        try await fetch(GitHubRelease.self, "repos/\(repo)/releases/latest", repo: repo, token: token)
    }

    /// The release tagged `tag`.
    static func fetchByTag(repo: String, tag: String, token: String?) async throws -> GitHubRelease {
        let escaped = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? tag
        return try await fetch(GitHubRelease.self, "repos/\(repo)/releases/tags/\(escaped)", repo: repo, token: token)
    }

    /// The most recent releases, newest first, without drafts. `perPage` is clamped to 1...100,
    /// as GitHub's API is.
    static func fetchRecent(repo: String, perPage: Int = 10, token: String?) async throws -> [GitHubRelease] {
        let clamped = max(1, min(100, perPage))
        let releases = try await fetch([GitHubRelease].self, "repos/\(repo)/releases?per_page=\(clamped)", repo: repo, token: token)
        return newestFirst(releases.filter { !$0.draft })
    }

    static func newestFirst(_ releases: [GitHubRelease]) -> [GitHubRelease] {
        // GitHub does not guarantee publication order here; rc.9 can precede rc.10.
        releases.sorted { lhs, rhs in
            let lhsDate = lhs.publishedAt ?? lhs.createdAt
            let rhsDate = rhs.publishedAt ?? rhs.createdAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id > rhs.id
        }
    }

    // MARK: - Assets

    /// The first asset in `release` matching `filter`, or `nil`. A pattern that isn't a regex
    /// matches nothing.
    static func selectAsset(in release: GitHubRelease, filter: GitHubAsset.Filter) -> GitHubAsset? {
        switch filter {
        case .pkg:
            return release.assets.first { $0.name.hasSuffix(".pkg") }
        case .filename(let name):
            return release.assets.first { $0.name == name }
        case .regex(let pattern):
            guard let regex = try? regex(pattern) else { return nil }
            return release.assets.first { matches(regex, $0.name) }
        }
    }

    /// The request that downloads `asset`.
    ///
    /// GitHub's `browser_download_url` is enough for public releases. Private releases require
    /// the asset API URL plus the octet-stream Accept header; GitHub responds with a redirect to
    /// a signed download URL.
    static func makeAssetDownloadRequest(asset: GitHubAsset, token: String?) -> URLRequest {
        guard let token = normalizedToken(token) else {
            return URLRequest(url: asset.downloadURL)
        }

        var request = URLRequest(url: asset.apiURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Private

    private static func fetch<T: Decodable>(_: T.Type, _ path: String, repo: String, token: String?) async throws -> T {
        let request = makeRequest(url: URL(string: "https://api.github.com/\(path)")!, token: token)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw GitHubReleasesError.requestFailed(repo: repo, status: status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func makeRequest(url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = normalizedToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func normalizedToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func regex(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            throw GitHubReleasesError.invalidPattern(pattern)
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Which release of a repo `Pkg(.gitHub(…))` installs: one tag, or the newest.
///
/// ```swift
/// Pkg(.gitHub("org/tool", tag: "v1.4.0"))                     // pinned
/// Pkg(.gitHub("org/tool", tag: .named(tag)))                  // pinned, from a variable
/// Pkg(.gitHub("org/tool", tag: .latest))                      // the newest release with the asset
/// Pkg(.gitHub("org/tool", tag: .latest(matching: #"^v2\."#))) // the newest 2.x
/// ```
public struct GitHubTag: Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    enum Kind: Sendable, Hashable {
        case named(String)
        case latest(GitHubReleases.Options)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    public init(stringLiteral tag: String) {
        kind = .named(tag)
    }

    /// Exactly this tag.
    public static func named(_ tag: String) -> GitHubTag {
        GitHubTag(.named(tag))
    }

    /// The newest release that isn't a draft or a prerelease and has the asset `Pkg` installs.
    public static var latest: GitHubTag { .latest() }

    /// The newest release, filtered as `GitHubReleases.latestTag` filters. Without `asset`, the
    /// release must have the asset `Pkg` installs, so a release whose assets are still
    /// uploading is skipped.
    ///
    /// Checked hourly. A new release moves the hash and upgrades in place. A failed check keeps
    /// the last tag, also across a restart, and never uninstalls.
    public static func latest(
        prereleases: Bool = false,
        matching tag: String? = nil,
        asset: GitHubAsset.Filter? = nil,
        order: GitHubReleases.Order = .published
    ) -> GitHubTag {
        GitHubTag(.latest(GitHubReleases.Options(prereleases: prereleases, tag: tag, asset: asset, order: order)))
    }

    /// A named tag is its string, as in a snapshot written before `.latest` existed.
    public init(from decoder: any Decoder) throws {
        if let tag = try? decoder.singleValueContainer().decode(String.self) {
            kind = .named(tag)
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = .latest(try container.decode(GitHubReleases.Options.self, forKey: .latest))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch kind {
        case .named(let tag):
            var container = encoder.singleValueContainer()
            try container.encode(tag)
        case .latest(let options):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(options, forKey: .latest)
        }
    }

    private enum CodingKeys: String, CodingKey { case latest }
}

/// Where a GitHub token is on the Mac. Only the reference is in the declaration and in
/// `records.json`; the token is read when it's used. Never part of a hash: rotating the token
/// reinstalls nothing.
public enum GitHubToken: Codable, Sendable, Hashable {
    /// A file holding the token, e.g. `/etc/astrolabe/github-token`, readable by root.
    case file(String)
    /// An environment variable of the daemon. launchd starts it with almost none: prefer `file`.
    case environment(String)

    enum FileCodingKeys: String, CodingKey { case _0 = "path" }
    enum EnvironmentCodingKeys: String, CodingKey { case _0 = "name" }

    /// The token, whitespace trimmed. Throws when it's missing or empty, rather than sending no
    /// token and reading a private repo as missing.
    func resolve() throws -> String {
        let token: String?
        switch self {
        case .file(let path):
            token = try? String(contentsOfFile: path, encoding: .utf8)
        case .environment(let name):
            token = ProcessInfo.processInfo.environment[name]
        }
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw GitHubReleasesError.tokenUnavailable(self)
        }
        return trimmed
    }
}

public enum GitHubReleasesError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The API answered with something other than 200: a wrong repo or tag, a private repo
    /// without a token, or rate limiting.
    case requestFailed(repo: String, status: Int)
    /// No release passed `latestTag`'s filters.
    case noMatchingRelease(repo: String)
    /// A `tag` or `asset` pattern that isn't a regex.
    case invalidPattern(String)
    /// The token's file or variable is missing or empty.
    case tokenUnavailable(GitHubToken)

    public var description: String {
        switch self {
        case .requestFailed(let repo, let status):
            "GitHub API request failed for \(repo) (status \(status))"
        case .noMatchingRelease(let repo):
            "no release of \(repo) matches"
        case .invalidPattern(let pattern):
            "not a regular expression: \(pattern)"
        case .tokenUnavailable(.file(let path)):
            "no GitHub token in \(path)"
        case .tokenUnavailable(.environment(let name)):
            "no GitHub token in $\(name)"
        }
    }
}

// MARK: - Wire models

/// A GitHub release as returned by the Releases API. Includes the fields we care about.
struct GitHubRelease: Decodable, Sendable {
    let id: Int
    let tagName: String
    let assets: [GitHubAsset]
    let prerelease: Bool
    let draft: Bool
    let createdAt: String
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case assets
        case prerelease
        case draft
        case createdAt = "created_at"
        case publishedAt = "published_at"
    }
}

/// A file attached to a GitHub release.
public struct GitHubAsset: Decodable, Sendable {
    let name: String
    let apiURL: URL
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case apiURL = "url"
        case downloadURL = "browser_download_url"
    }

    /// Which asset of a release to take.
    public enum Filter: Codable, Sendable, Hashable {
        /// The first asset whose name ends in `.pkg`. The default.
        case pkg
        /// The asset with exactly this name.
        case filename(String)
        /// The first asset whose name matches this regex, e.g. `arm64\.pkg$`.
        case regex(String)

        enum FilenameCodingKeys: String, CodingKey { case _0 = "name" }
        enum RegexCodingKeys: String, CodingKey { case _0 = "pattern" }

        /// What `PkgInstall.compute` hashes.
        var hashDescription: String {
            switch self {
            case .pkg: "pkg"
            case .filename(let name): "filename:\(name)"
            case .regex(let pattern): "regex:\(pattern)"
            }
        }
    }
}
