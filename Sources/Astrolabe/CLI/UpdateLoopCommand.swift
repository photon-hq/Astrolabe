import ArgumentParser
import Foundation

/// Hidden subcommand invoked by the updater daemon's launchd plist.
///
/// Not shown in `--help`. Users should never invoke this directly; it loops
/// until launchd terminates the process.
struct UpdateLoopCommand<App: Astrolabe>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "__update-loop",
            abstract: "Internal: run the self-update polling loop.",
            shouldDisplay: false
        )
    }

    mutating func run() async throws {
        _ = App()                     // run init() for side effects (poll interval, etc.)
        StorageStore.shared.load()

        guard let cfg = App.update else {
            print("[Astrolabe] No update configuration — exiting update loop.")
            return
        }
        await UpdateLoop.run(configuration: cfg, currentVersion: App.version)
    }
}
