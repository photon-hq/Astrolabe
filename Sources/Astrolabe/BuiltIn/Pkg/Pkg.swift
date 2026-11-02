import CryptoKit
import Foundation

/// Keeps a `.pkg` installed, from a GitHub release or a URL.
///
/// ```swift
/// var body: some Component {
///     Pkg(.gitHub("org/tool", tag: "v1.4.0"))
///     Pkg(.gitHub("org/other", tag: .latest))
///     Pkg(.gitHub("org/private", tag: .named(tag), asset: .regex(#"arm64\.pkg$"#), token: .file("/etc/astrolabe/github-token")))
///     Pkg(.url(URL(string: "https://example.com/x-2.1.pkg")!, name: "x", sha256: "…"))
/// }
/// ```
///
/// The id is the source's key: the repo, or the URL source's `name`. A new tag or URL keeps the
/// id and moves the hash, so it upgrades in place: `installer` over the old version, then the
/// receipts the new version no longer writes are uninstalled. `tag: .latest` follows the repo's
/// newest release, checked hourly: until its first check lands, nothing is declared, unless
/// it's already installed, which then stays as it is.
///
/// Nobody declares a receipt. Each rollout reads the package's receipt ids from the `.pkg`
/// itself, keeps those `installer` wrote, and saves them in a marker under
/// `/Library/Application Support/Astrolabe/pkg/`. A receipt that goes missing (`pkgutil
/// --forget`) is installed again within a minute.
///
/// Dropping it from `body` uninstalls it, also after a restart: every file its receipts list
/// that no other receipt claims, its launchd jobs booted out first, then its emptied
/// directories, and the receipts. Uninstall scripts and per-user leftovers are not run or found.
///
/// Signed packages only, unless `allowUntrusted`. The token is read when it's used: only its
/// file or variable name is in `records.json`.
public struct Pkg: Component {
    let source: PkgSource
    let allowUntrusted: Bool

    public init(_ source: PkgSource, allowUntrusted: Bool = false) {
        self.source = source
        self.allowUntrusted = allowUntrusted
    }

    public var body: some Component {
        if let source = resolved {
            PkgInstall(source: source, allowUntrusted: allowUntrusted)
        }
    }

    /// The source with `.latest` replaced by the tag it reads. Until that's known: `nil` on a Mac
    /// without it, and `.latest` itself when a marker says it's installed, so a new query (a
    /// pinned tag turned `.latest`, a filter or token changed) never uninstalls it. That rollout
    /// fails until the tag lands, and the tag's hash then replaces it.
    private var resolved: PkgSource? {
        guard case .gitHub(let repo, let tag, let asset, let token) = source, case .latest(var options) = tag.kind else {
            return source
        }
        options.asset = options.asset ?? asset
        let query = LatestTagQuery(repo: repo, token: token, options: options)
        guard let latest = Fact(\.pkgs[latest: query]).wrappedValue else {
            return Fact(\.pkgs[marked: repo]).wrappedValue ? source : nil
        }
        return .gitHub(repo, tag: .named(latest), asset: asset, token: token)
    }
}

/// Where a `.pkg` comes from.
public enum PkgSource: Codable, Sendable, Hashable {
    /// The release of `repo` (`org/tool`) tagged `tag`, or its newest with `.latest`, and its
    /// first asset matching `asset`. A `token` reads private repos.
    case gitHub(_ repo: String, tag: GitHubTag, asset: GitHubAsset.Filter = .pkg, token: GitHubToken? = nil)
    /// The `.pkg` at `url`. `name` keys it, since each version has its own URL. With `sha256`,
    /// a download that doesn't match is never installed.
    case url(_ url: URL, name: String, sha256: String? = nil)

    enum GitHubCodingKeys: String, CodingKey { case _0 = "repo", tag, asset, token }
    enum UrlCodingKeys: String, CodingKey { case _0 = "url", name, sha256 }

    /// What stays the same from one version to the next: the repo, or the URL source's `name`.
    public var key: String {
        switch self {
        case .gitHub(let repo, _, _, _): repo
        case .url(_, let name, _): name
        }
    }
}

/// Keeps one `.pkg` installed at the declared version. Declared by `Pkg`.
@Resource
struct PkgInstall {
    static let kind = "astrolabe.pkg"
    let source: PkgSource
    let allowUntrusted: Bool
    /// The marker is there and every receipt in it is on the Mac. A forgotten receipt (false)
    /// reruns `rollout`, which installs it again.
    @Monitor var installed: Bool?

    init(source: PkgSource, allowUntrusted: Bool) {
        self.source = source
        self.allowUntrusted = allowUntrusted
        _installed = Monitor(\.pkgs[installed: source.key])
    }

    var id: String { "pkg:\(source.key)" }

    /// Everything that picks the package, never the token: rotating it reinstalls nothing.
    static func compute(_ pkg: Self) -> String {
        switch pkg.source {
        case .gitHub(let repo, let tag, let asset, _):
            Hash.of(kind, "gitHub", repo, tag.hashDescription, asset.hashDescription, pkg.allowUntrusted)
        case .url(let url, let name, let sha256):
            Hash.of(kind, "url", name, url.absoluteString, sha256?.lowercased(), pkg.allowUntrusted)
        }
    }

    @concurrent static func rollout(_ pkg: Self) async throws {
        let source = pkg.source
        // Declared only to keep an installed package while its tag isn't known. Fails before the
        // lock, so it never queues behind another package's install.
        if case .gitHub(let repo, let tag, _, _) = source, case .latest = tag.kind {
            throw PkgError.unresolvedTag(repo: repo)
        }
        try await PkgInstaller.install(key: source.key, hash: compute(pkg), allowUntrusted: pkg.allowUntrusted) { directory in
            try await source.fetch(into: directory, PkgContext.current.system)
        }
    }

    /// Uses only the key: the marker says what's installed.
    @concurrent static func remove(_ pkg: Self) async throws {
        try await PkgInstaller.uninstall(key: pkg.source.key)
    }

    /// Failures are mostly network, a release without its asset yet, or a signature.
    static var retryPolicy: RetryPolicy { .retry(Backoff(initial: .seconds(60), max: .seconds(3600))) }

    /// Waiting out other packages for the lock, the download, and `installer`.
    static var timeout: Duration { .seconds(2 * 3600) }
}

extension PkgSource {
    /// Downloads the `.pkg` into `directory` and returns its path. Checks the URL source's
    /// `sha256`. Resolves the token here, never earlier.
    func fetch(into directory: URL, _ system: any PkgSystem) async throws -> URL {
        let destination = directory.appendingPathComponent("package.pkg")
        switch self {
        case .gitHub(let repo, let gitHubTag, let filter, let token):
            // `Pkg.body` always resolves `.latest` first.
            guard case .named(let tag) = gitHubTag.kind else { throw PkgError.unresolvedTag(repo: repo) }
            let token = try token?.resolve()
            let release = try await system.release(repo, tag: tag, token: token)
            guard let asset = GitHubReleases.selectAsset(in: release, filter: filter) else {
                throw PkgError.noMatchingAsset(repo: repo, tag: tag)
            }
            print("[Astrolabe] pkg \(repo): downloading \(asset.name) from \(tag)")
            try await system.download(GitHubReleases.makeAssetDownloadRequest(asset: asset, token: token), to: destination)
        case .url(let url, let name, let sha256):
            print("[Astrolabe] pkg \(name): downloading \(url.absoluteString)")
            try await system.download(URLRequest(url: url), to: destination)
            if let sha256 {
                let actual = try Self.sha256(of: destination)
                guard actual == sha256.lowercased() else {
                    throw PkgError.checksumMismatch(name: name, expected: sha256.lowercased(), actual: actual)
                }
            }
        }
        return destination
    }

    /// The lowercase hex SHA-256 of the file, read in chunks.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension GitHubTag {
    /// What `PkgInstall.compute` hashes: a named tag is its string, as before `.latest` existed.
    var hashDescription: String {
        switch kind {
        case .named(let tag): tag
        case .latest: "latest"
        }
    }
}
