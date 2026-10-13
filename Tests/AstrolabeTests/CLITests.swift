import ArgumentParser
import Foundation
import Testing
@testable import Astrolabe

// MARK: - Test fixtures

private struct CLITestApp: Astrolabe {
    var body: some Component { EmptyComponent() }
}

// MARK: - Dispatch

private func commandName(_ type: any ParsableCommand.Type) -> String {
    type.configuration.commandName ?? String(describing: type).lowercased()
}

@Test func rootConfigurationIncludesFrameworkSubcommands() {
    let names = AstrolabeRoot<CLITestApp>.configuration.subcommands.map(commandName)
    #expect(names == ["run", "install-daemon", "uninstall-daemon"])
}

@Test func defaultSubcommandIsRunEngine() {
    guard let defaultType = AstrolabeRoot<CLITestApp>.configuration.defaultSubcommand else {
        Issue.record("Expected a default subcommand")
        return
    }
    #expect(commandName(defaultType) == "run")
}

@Test func runEngineParsesDryRun() throws {
    #expect(try RunEngine<CLITestApp>.parse(["--dry-run"]).dryRun == true)
    #expect(try RunEngine<CLITestApp>.parse([]).dryRun == false)
}

@Test func rootRoutesBareDryRunToRunEngine() throws {
    let command = try AstrolabeRoot<CLITestApp>.parseAsRoot(["--dry-run"])
    let run = try #require(command as? RunEngine<CLITestApp>)
    #expect(run.dryRun)
}

@Test func installDaemonParsesForceFlag() throws {
    let parsed = try InstallDaemon.parse(["--force"])
    #expect(parsed.force == true)
}

@Test func installDaemonDefaultsForceFalse() throws {
    let parsed = try InstallDaemon.parse([])
    #expect(parsed.force == false)
}

@Test func unknownSubcommandFailsToParse() {
    #expect(throws: (any Error).self) {
        _ = try AstrolabeRoot<CLITestApp>.parseAsRoot(["bogus"])
    }
}
