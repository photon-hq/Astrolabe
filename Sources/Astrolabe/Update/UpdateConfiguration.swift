import Foundation

// MARK: - Duration sugar

extension Duration {
    /// `Duration` representing `count` minutes.
    public static func minutes(_ count: Int) -> Duration { .seconds(count * 60) }
    /// `Duration` representing `count` hours.
    public static func hours(_ count: Int)   -> Duration { .seconds(count * 3600) }
}

/// Declarative configuration for Astrolabe's self-update mechanism.
///
/// Set `static var update` on your `Astrolabe`-conforming type to opt in. When
/// non-`nil`, `install-daemon` provisions a sibling LaunchDaemon (`<label>.updater`)
/// that polls the configured source on the configured interval and replaces this
/// binary when a newer release is available.
///
/// ```swift
/// // Minimum — autodetect .pkg asset, hourly, stable channel, pkg-signature required.
/// static var update: UpdateConfiguration? {
///     UpdateConfiguration(.gitHub("acme/mysetup"))
/// }
///
/// // Full — every knob.
/// static var update: UpdateConfiguration? {
///     UpdateConfiguration(.gitHub("acme/mysetup", asset: .pkg))
///         .interval(.hours(1))
///         .channel(.stable)
///         .verify(.codesignTeamID("ABCD1234"))
///         .allowDowngrade(false)
///         .githubToken(token)
///         .preUpdate  { from, to in try await backupConfigs() }
///         .postUpdate { v in await reportToMDM(v) }
///         .onFail     { error in print(error) }
/// }
/// ```
///
/// `UpdateConfiguration` is immutable; modifiers return a copy. It is not a `Setup`
/// node — the updater is a sibling process, not part of the convergence tree.
public struct UpdateConfiguration: Sendable {
    public typealias PreUpdateHook  = @Sendable (_ from: String, _ to: String) async throws -> Void
    public typealias PostUpdateHook = @Sendable (_ version: String) async -> Void
    public typealias FailHook       = @Sendable (any Error) async -> Void

    /// Which releases to consider when polling for updates.
    public enum Channel: String, Sendable {
        /// Only releases marked as `latest` on the source (default).
        case stable
        /// Include pre-releases. Picks the newest non-draft release.
        case prerelease
    }

    public let source: any UpdateSource
    public var interval: Duration
    public var channel: Channel
    public var verification: UpdateVerification
    public var allowDowngrade: Bool
    public var githubToken: String?
    public var preUpdate:  PreUpdateHook?
    public var postUpdate: PostUpdateHook?
    public var onFail:     FailHook?

    public init(_ source: any UpdateSource) {
        self.source = source
        self.interval = .seconds(3600)
        self.channel = .stable
        self.verification = .pkgSignatureRequired
        self.allowDowngrade = false
        self.githubToken = nil
        self.preUpdate = nil
        self.postUpdate = nil
        self.onFail = nil
    }

    // MARK: - Modifiers (copy-on-write, chainable)

    /// How often the updater polls the source. Default: 1 hour.
    public func interval(_ duration: Duration) -> Self {
        var copy = self; copy.interval = duration; return copy
    }

    /// Which release channel to track. Default: `.stable`.
    public func channel(_ channel: Channel) -> Self {
        var copy = self; copy.channel = channel; return copy
    }

    /// How to verify the downloaded artifact. Default: `.pkgSignatureRequired`.
    public func verify(_ verification: UpdateVerification) -> Self {
        var copy = self; copy.verification = verification; return copy
    }

    /// Whether to install a release whose SemVer is lower than the current
    /// binary's version. Default: `false` (refuse downgrade).
    public func allowDowngrade(_ allow: Bool = true) -> Self {
        var copy = self; copy.allowDowngrade = allow; return copy
    }

    /// GitHub API token. Baked into the updater daemon's plist `EnvironmentVariables`
    /// as `GITHUB_TOKEN` so the out-of-process updater can use it. Default: `nil`.
    public func githubToken(_ token: String?) -> Self {
        var copy = self; copy.githubToken = token; return copy
    }

    /// Async hook run after a newer release is verified and *before* the
    /// installer runs. Throwing aborts the update; the temp pkg is cleaned up.
    public func preUpdate(_ handler: @escaping PreUpdateHook) -> Self {
        var copy = self; copy.preUpdate = handler; return copy
    }

    /// Async hook run after the installer succeeds, before kickstarting the
    /// main daemon. Receives the new version string.
    public func postUpdate(_ handler: @escaping PostUpdateHook) -> Self {
        var copy = self; copy.postUpdate = handler; return copy
    }

    /// Async hook run when any step of the update fails. Receives the error.
    /// The updater logs and proceeds to the next tick.
    public func onFail(_ handler: @escaping FailHook) -> Self {
        var copy = self; copy.onFail = handler; return copy
    }
}
