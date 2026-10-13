import ArgumentParser

struct UninstallDaemon: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "uninstall-daemon",
            abstract: "Uninstall the Astrolabe LaunchDaemon."
        )
    }

    mutating func run() async throws {
        await DaemonManager.removeDaemon()
    }
}
