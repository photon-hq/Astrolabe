extension Facts {
    /// Facts about Homebrew. Reads nothing by itself.
    public var homebrew: HomebrewFacts { HomebrewFacts(facts: self) }
}

/// Who owns Homebrew at `/opt/homebrew`, and whether it's there.
public struct HomebrewFacts: FactNamespace {
    public let facts: Facts

    /// Every account that owns part of Homebrew, sorted, without duplicates. `[]` when
    /// `/opt/homebrew/bin/brew` isn't there. An owner with no account reads as `#<uid>`.
    ///
    /// Reads the owner of `/opt/homebrew`, of `Cellar`, `Caskroom`, `opt` and `bin`, and of each
    /// entry directly inside those: where every `brew install` creates something. `lstat` only,
    /// never following a link: a few hundred calls and no subprocess, so every minute is cheap.
    ///
    /// Read under the same lock as `Homebrew`'s rollout, so it never sees an install half done.
    /// It waits out an install in progress, so the timeout outlasts the longest lock hold: a
    /// re-own, `install.sh`, and the checks after.
    @FactEntry(schedule: .every(.seconds(60)), timeout: .seconds(100 * 60), read: {
        try await HomebrewReads.owners()
    })
    public var owners: [String] = []

    /// Whether `brew` is at the prefix. Tracked through `owners`.
    public var isInstalled: Bool { !owners.isEmpty }
}

/// The reads behind `HomebrewFacts`, on the task-local context.
enum HomebrewReads {
    static func owners() async throws -> [String] {
        let context = HomebrewContext.current
        return try await HomebrewInstaller.locked(context) { try context.system.owners() }
    }
}
