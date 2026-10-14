import Astrolabe
import Foundation

/// Exercises `Homebrew` on a farm Mac or a clean Apple-silicon VM, ideally at the login window.
///
/// Write the owner's short name (`whoami`) to `/etc/astrolabe-homebrew-owner`, then run it:
///
/// ```sh
/// echo ops | sudo tee /etc/astrolabe-homebrew-owner
/// sudo .build/release/HomebrewEngine --dry-run   # rollout commandLineTools@…; no homebrew until CLT is there
/// sudo .build/release/HomebrewEngine             # installs the daemon
/// ```
///
/// CLT installs first; within about a minute of it landing, Homebrew does, owned by the owner.
/// Write another account to the file and the prefix is re-owned, with nothing downloaded. Empty
/// the file and Homebrew is no longer declared, which leaves it in place.
///
/// The owner comes from a file, not an environment variable: the daemon launchd starts never
/// sees the environment of the `sudo` that installed it.
@main
struct HomebrewApp: Astrolabe {
    @Fact(\.homebrewOwner) var owner

    var body: some Component {
        CommandLineTools()
        if let owner {
            Homebrew(owner: owner)
        }
    }
}

extension Facts {
    /// The first line of `/etc/astrolabe-homebrew-owner`, or `nil` when it's missing or empty.
    @FactEntry(schedule: .every(.seconds(5)), read: { OwnerFile.read() })
    var homebrewOwner: String?
}

enum OwnerFile {
    static let path = "/etc/astrolabe-homebrew-owner"

    /// Never throws: a missing file is a real reading, "no owner", not a failed one.
    static func read() -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let owner = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return owner.isEmpty ? nil : owner
    }
}
