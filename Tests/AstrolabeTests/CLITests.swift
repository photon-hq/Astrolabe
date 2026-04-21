import ArgumentParser
import Foundation
import Testing
@testable import Astrolabe

// MARK: - Test fixtures

private struct TestApp: Astrolabe {
    init() {}
    var body: some Setup { EmptySetup() }
    static var commands: [any AsyncParsableCommand.Type] { [TestAbc.self] }
}

private struct TestAbc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "abc",
        abstract: "Test subcommand."
    )

    @Argument var target: String = "default"
    @Flag(name: .shortAndLong) var verbose = false

    func run() async throws {}
}

// MARK: - Dispatch

private func commandName(_ type: any ParsableCommand.Type) -> String {
    type.configuration.commandName ?? String(describing: type).lowercased()
}

@Test func rootConfigurationIncludesFrameworkAndConsumerSubcommands() {
    let names = AstrolabeRoot<TestApp>.configuration.subcommands.map(commandName)
    #expect(names.contains("run"))
    #expect(names.contains("install-daemon"))
    #expect(names.contains("uninstall-daemon"))
    #expect(names.contains("abc"))
}

@Test func defaultSubcommandIsRunEngine() {
    guard let defaultType = AstrolabeRoot<TestApp>.configuration.defaultSubcommand else {
        Issue.record("Expected a default subcommand")
        return
    }
    #expect(commandName(defaultType) == "run")
}

@Test func consumerCommandParsesArgsAndFlags() throws {
    let parsed = try TestAbc.parse(["target-value", "--verbose"])
    #expect(parsed.target == "target-value")
    #expect(parsed.verbose == true)
}

@Test func installDaemonParsesForceFlag() throws {
    let parsed = try InstallDaemon<TestApp>.parse(["--force"])
    #expect(parsed.force == true)
}

@Test func installDaemonDefaultsForceFalse() throws {
    let parsed = try InstallDaemon<TestApp>.parse([])
    #expect(parsed.force == false)
}

@Test func unknownSubcommandFailsToParse() {
    #expect(throws: (any Error).self) {
        _ = try AstrolabeRoot<TestApp>.parseAsRoot(["bogus"])
    }
}
