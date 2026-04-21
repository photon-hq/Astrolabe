import ArgumentParser
import Foundation

struct InstallDaemon<App: Astrolabe>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "install-daemon",
            abstract: "Install or update the Astrolabe LaunchDaemon."
        )
    }

    @Flag(help: "Re-install even if the daemon is already loaded.")
    var force: Bool = false

    mutating func run() async throws {
        _ = App()
        guard App.daemonMode else {
            FileHandle.standardError.write(Data(
                "[Astrolabe] daemonMode is false — refusing to install.\n".utf8
            ))
            throw ExitCode.failure
        }
        try await DaemonManager.installOrUpdateDaemon(force: force)
    }
}
