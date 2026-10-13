import Astrolabe

/// Exercises the v2 engine on a staging host.
///
/// `sudo` edit `/tmp/astrolabe-staging/state.json` — a map of file name to contents — and the
/// engine makes `/tmp/astrolabe-staging/<name>` match it:
///
/// ```sh
/// sudo mkdir -p /tmp/astrolabe-staging
/// echo '{"a.txt": "1"}' | sudo tee /tmp/astrolabe-staging/state.json
/// sudo .build/release/StagingEngine             # installs the daemon
/// sudo .build/release/StagingEngine --dry-run   # prints the diff, changes nothing
/// ```
///
/// Each rollout waits 10 seconds before writing, a window to change state mid-rollout.
/// Contents starting with `FAIL` make the rollout throw, to exercise `.rollback`.
@main
struct StagingApp: Astrolabe {
    /// Created once: the engine holds this app value for its whole run.
    let fixture = Fixture.watching(StateFile.path)

    var body: some Component {
        for (name, contents) in fixture.files.sorted(by: { $0.key < $1.key }) {
            StagingFile(path: "\(StateFile.directory)/\(name)", contents: contents)
        }
    }

    static var resourceTypes: [any Resource.Type] { [StagingFile.self] }
}
