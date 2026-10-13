import ArgumentParser

struct InstallDaemon: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "install-daemon",
            abstract: "Install or update the Astrolabe LaunchDaemon."
        )
    }

    @Flag(help: "Re-install even if the daemon is already loaded.")
    var force: Bool = false

    mutating func run() async throws {
        try await DaemonManager.installOrUpdateDaemon(force: force)
    }
}
