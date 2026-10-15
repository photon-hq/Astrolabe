import Astrolabe
import Foundation

/// Exercises `Brew` on a farm Mac or a clean Apple-silicon VM.
///
/// Write the owner's short name (`whoami`) to `/etc/astrolabe-homebrew-owner`, and the packages
/// to `/etc/astrolabe-brew-packages`, one per line:
///
/// ```
/// wget
/// cask firefox
/// tailscale >= 1.102.0
/// ```
///
/// ```sh
/// echo ops | sudo tee /etc/astrolabe-homebrew-owner
/// printf 'wget\ncask firefox\n' | sudo tee /etc/astrolabe-brew-packages.new >/dev/null
/// sudo mv /etc/astrolabe-brew-packages.new /etc/astrolabe-brew-packages
/// sudo .build/release/BrewEngine --dry-run   # rollout brew:formula:wget@…, once Homebrew is there
/// sudo .build/release/BrewEngine             # installs the daemon
/// ```
///
/// Write the list to a temp file and `mv` it into place: `sudo tee` truncates first, and a read
/// in that instant would see an empty list and uninstall everything.
///
/// Add a line and the package installs. Remove it and it's uninstalled. Run
/// `brew as-brew-user uninstall wget` and it's back within a minute.
@main
struct BrewApp: Astrolabe {
    @Fact(\.homebrewOwner) var owner
    @Fact(\.brewList) var packages

    var body: some Component {
        CommandLineTools()
        if let owner {
            Homebrew(owner: owner)
        }
        for package in packages {
            Brew(package.name, type: package.type, version: package.version)
        }
    }
}

extension Facts {
    /// The first line of `/etc/astrolabe-homebrew-owner`, or `nil` when it's missing or empty.
    @FactEntry(schedule: .every(.seconds(5)), read: { OwnerFile.read() })
    var homebrewOwner: String?

    /// A missing file reads as `[]`: nothing declared. An unreadable file or an unparseable line
    /// throws, so the engine keeps the last list rather than uninstalling everything.
    @FactEntry(schedule: .every(.seconds(5)), read: { try PackageFile.read() })
    var brewList: [ListedPackage] = []
}

/// One line of `/etc/astrolabe-brew-packages`.
struct ListedPackage: Equatable, Sendable {
    let name: String
    let type: Brew.PackageType
    let version: Brew.Version
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

/// `[cask] <name> [>= <version>]` per line. Blank lines and `#` comments are skipped.
enum PackageFile {
    static let path = "/etc/astrolabe-brew-packages"

    struct UnparseableLine: Error, CustomStringConvertible {
        let number: Int
        let line: String
        var description: String { "\(PackageFile.path):\(number): expected `[cask] <name> [>= <version>]`, got `\(line)`" }
    }

    static func read() throws -> [ListedPackage] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var packages: [ListedPackage] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let content = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            guard let package = parse(content) else { throw UnparseableLine(number: index + 1, line: String(line)) }
            packages.append(package)
        }
        return packages
    }

    private static func parse(_ line: String) -> ListedPackage? {
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var type = Brew.PackageType.formula
        if words.first == "cask" {
            type = .cask
            words.removeFirst()
        }
        switch words.count {
        case 1:
            return ListedPackage(name: words[0], type: type, version: .installed)
        case 3 where words[1] == ">=":
            return ListedPackage(name: words[0], type: type, version: .atLeast(words[2]))
        default:
            return nil
        }
    }
}
