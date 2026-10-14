/// Keeps the Xcode Command Line Tools installed, headlessly, through `softwareupdate`.
///
/// ```swift
/// var body: some Component {
///     CommandLineTools()                      // install if missing
///     CommandLineTools(version: .latest)      // …and keep it at the newest Apple offers
/// }
/// ```
///
/// Installs the newest CLT Apple offers this macOS, and installs it again if someone deletes it:
/// `installed` is read every 15 minutes. Never downgrades, never uninstalls: dropping it from
/// `body` leaves CLT in place.
public struct CommandLineTools: Component {
    public enum Version: Sendable, Equatable {
        /// Any installed version. Installs the newest if missing, never updates. The default.
        case installed
        /// Also updates when Apple ships a newer CLT for this macOS (checked every 6 hours) or
        /// after a macOS upgrade.
        case latest
    }

    let version: Version
    @Fact(\.commandLineTools.latestAvailable) private var latestAvailable

    public init(version: Version = .installed) {
        self.version = version
    }

    public var body: some Component {
        CommandLineToolsInstall(minimum: minimum)
    }

    /// Only `.latest` reads `latestAvailable`, so only it starts the catalog checks. Both read
    /// `installed`, through the resource's monitor: the first pass waits for that read, which is
    /// fast and never contacts Apple.
    private var minimum: CLTVersion? {
        switch version {
        case .installed: nil
        case .latest: latestAvailable
        }
    }
}

/// Keeps the Xcode Command Line Tools at `minimum` or newer. Declared by `CommandLineTools`.
@Resource
struct CommandLineToolsInstall {
    static let kind = "astrolabe.commandLineTools"
    /// `nil` under `.installed`, and under `.latest` before the newest is known: any installed
    /// version will do, and a missing CLT gets the newest Apple offers.
    let minimum: CLTVersion?
    /// A deletion reruns `rollout`, which installs CLT again. An update changes nothing.
    @Monitor(\.commandLineTools.isInstalled) var isInstalled

    /// One per Mac.
    var id: String { "commandLineTools" }

    static func compute(_ resource: Self) -> String {
        Hash.of(kind, resource.minimum?.description)
    }

    @concurrent static func rollout(_ resource: Self) async throws {
        try await CLTInstaller.ensure(minimum: resource.minimum)
    }

    /// Never uninstalls: `brew` and every build on the Mac need CLT, and nothing would put it back.
    @concurrent static func remove(_ resource: Self) async throws {}

    /// Failures are mostly network (catalog unreachable), and each attempt lists the catalog.
    static var retryPolicy: RetryPolicy { .retry(Backoff(initial: .seconds(120), max: .seconds(3600))) }

    /// Waiting out another holder of the lock (e.g. Homebrew's `ensure`), plus a listing and an
    /// install of its own.
    static var timeout: Duration { .seconds(3 * 3600) }
}
