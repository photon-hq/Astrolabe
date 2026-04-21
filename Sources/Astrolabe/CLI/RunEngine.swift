import ArgumentParser
import Darwin
import Foundation

/// Default subcommand. With no args (launchd path), runs today's behavior:
/// install the daemon on first invocation, or run the convergence engine when
/// started by launchd. Disabled if `daemonMode = false` — the engine runs inline.
struct RunEngine<App: Astrolabe>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "run",
            abstract: "Run the convergence engine (default)."
        )
    }

    mutating func run() async throws {
        let configuration = App()

        if App.daemonMode {
            if !DaemonManager.isLaunchdChild {
                try await DaemonManager.installOrUpdateDaemon()
                return
            }
            print("[Astrolabe] Running as daemon.")
        } else {
            await DaemonManager.removeDaemon()
        }

        let engine = LifecycleEngine(
            configuration: configuration,
            providers: [EnrollmentProvider()],
            pollInterval: App.pollInterval
        )
        try await engine.run()
    }
}
