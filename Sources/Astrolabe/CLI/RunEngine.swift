import ArgumentParser
import Darwin
import Foundation

/// Default subcommand. Installs the daemon on first invocation, or runs the engine when started
/// by launchd. With `--dry-run` the engine runs inline and only prints what it would do.
struct RunEngine<App: Astrolabe>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "run",
            abstract: "Run the state engine (default)."
        )
    }

    @Flag(help: "Run inline and print the diff each pass. Never acts, never writes records.")
    var dryRun = false

    mutating func run() async throws {
        let mode: EngineMode = dryRun ? .dryRun : .apply
        if mode == .apply {
            if !DaemonManager.isLaunchdChild {
                try await DaemonManager.installOrUpdateDaemon()
                return
            }
            print("[Astrolabe] Running as daemon.")
        }
        await Self.runEngine(mode: mode)
    }

    /// Runs the engine until SIGTERM or SIGINT, then exits.
    @MainActor
    private static func runEngine(mode: EngineMode) async -> Never {
        let telemetry = App.telemetry
        let engine = Engine(
            app: App(),
            resourceTypes: ResourceRecords.linkedTypes(),
            store: RecordStore(url: Persistence.recordsURL),
            mode: mode,
            telemetry: telemetry
        )
        let run = Task { await engine.run() }
        await Signals.awaitTermination()
        // The engine cancels everything in flight and waits for it before returning.
        run.cancel()
        await run.value
        telemetry.shutdown()
        Darwin.exit(0)
    }
}
