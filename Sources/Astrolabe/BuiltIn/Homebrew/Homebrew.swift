/// Keeps Homebrew installed at `/opt/homebrew` and owned by `owner`, headlessly, with Homebrew's
/// own `install.sh`.
///
/// ```swift
/// var body: some Component {
///     CommandLineTools()             // required: Homebrew waits for it and never installs it
///     Homebrew(owner: "ops")
/// }
/// ```
///
/// `owner` is one account's short name (what `whoami` prints), never root. Every `brew` runs as
/// it. Run `brew` by hand as the owner too: `brew as-brew-user install wget`. Files anyone else
/// creates in the prefix are given back to `owner` within a minute.
///
/// Declares nothing until CLT is on the Mac. Without `CommandLineTools()` in `body`, Homebrew
/// waits forever, and nothing logs it: the dry run shows no `homebrew` id.
///
/// A deleted Homebrew is installed again. Changing `owner` re-owns the prefix. Keeping Homebrew
/// current is `brew update`'s job. Never uninstalls: dropping it from `body` leaves Homebrew and
/// every formula in place. Apple silicon only, as Homebrew is on macOS.
public struct Homebrew: Component {
    let owner: String
    @Fact(\.commandLineTools.isInstalled) private var commandLineToolsInstalled

    public init(owner: String) {
        self.owner = owner
    }

    public var body: some Component {
        // Safe to gate: `HomebrewInstall.remove` does nothing, so CLT vanishing removes nothing.
        if commandLineToolsInstalled {
            HomebrewInstall(owner: owner)
        }
    }
}

/// Keeps Homebrew installed and owned by `owner` alone. Declared by `Homebrew`.
@Resource
struct HomebrewInstall {
    static let kind = "astrolabe.homebrew"
    /// Owns the prefix. Every later `brew` runs as this user.
    let owner: String
    /// Deleted (`[]`), re-owned, or mixed (`["bob", "ops"]`) reruns `rollout`. `brew update`
    /// changes nothing.
    @Monitor(\.homebrew.owners) var owners

    /// One per Mac.
    var id: String { "homebrew" }

    static func compute(_ resource: Self) -> String {
        Hash.of(kind, resource.owner)
    }

    @concurrent static func rollout(_ resource: Self) async throws {
        try await HomebrewInstaller.ensure(owner: resource.owner)
    }

    /// Never uninstalls: that deletes every formula on the Mac, and nothing would put them back.
    @concurrent static func remove(_ resource: Self) async throws {}

    /// Failures are mostly network, a missing CLT, or a missing owner, and each install fetches
    /// Homebrew from GitHub.
    static var retryPolicy: RetryPolicy { .retry(Backoff(initial: .seconds(60), max: .seconds(3600))) }

    /// Waiting out another holder of the lock, plus a re-own, `install.sh`, and the checks.
    static var timeout: Duration { .seconds(3 * 3600) }
}
