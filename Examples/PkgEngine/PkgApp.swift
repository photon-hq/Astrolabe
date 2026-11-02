import Astrolabe

/// Exercises `Pkg` on a VM or a spare Mac: keeps the latest release `.pkg` of
/// [Installomator](https://github.com/Installomator/Installomator) installed, a single script
/// under `/usr/local/Installomator`.
///
/// ```sh
/// sudo .build/debug/PkgEngine --dry-run   # rollout pkg:Installomator/Installomator@…, once the tag is read
/// sudo .build/debug/PkgEngine             # installs the daemon
/// pkgutil --pkgs | grep -i installomator  # the receipt rollout read from the .pkg
/// ls "/Library/Application Support/Astrolabe/pkg/"
/// ```
///
/// `sudo pkgutil --forget <id>` and it's installed again within a minute. A new release
/// upgrades it in place within the hour. Pin it with `tag: "v10.8"`; drop the line and it's
/// uninstalled, also across a restart.
@main
struct PkgApp: Astrolabe {
    var body: some Component {
        Pkg(.gitHub("Installomator/Installomator", tag: .latest))
    }
}
