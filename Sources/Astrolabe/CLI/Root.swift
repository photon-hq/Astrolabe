import ArgumentParser
import Foundation

struct AstrolabeRoot<App: Astrolabe>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: executableName(),
            abstract: "Astrolabe declarative macOS configuration.",
            subcommands: [
                RunEngine<App>.self,
                InstallDaemon.self,
                UninstallDaemon.self,
            ],
            defaultSubcommand: RunEngine<App>.self
        )
    }

    private static func executableName() -> String {
        (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "astrolabe"
    }
}
