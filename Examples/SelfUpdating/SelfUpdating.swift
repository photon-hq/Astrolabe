import Astrolabe

/// Demonstrates self-updating Astrolabe binaries.
///
/// When this binary is deployed, `install-daemon` provisions two LaunchDaemons:
///
///   1. `codes.photon.astrolabe`         — the main convergence engine.
///   2. `codes.photon.astrolabe.updater` — polls GitHub for new releases of
///      `acme/mysetup`, downloads `.pkg`s, verifies their Apple signature,
///      installs them via `/usr/sbin/installer`, then restarts both daemons.
///
/// Bump `version` on every release. The updater compares it against the
/// repo's release tags (parsed as SemVer) and refuses downgrades by default.
@main
struct SelfUpdating: Astrolabe {
    static var version: String { "0.0.1" }

    static var update: UpdateConfiguration? {
        UpdateConfiguration(.gitHub("acme/mysetup"))
            .interval(.hours(1))
            .channel(.stable)
            .verify(.pkgSignatureRequired)
            .onFail { error in
                print("[SelfUpdating] update failed: \(error)")
            }
    }

    var body: some Setup {
        Pkg(.catalog(.homebrew))
        Brew("jq")
    }
}
