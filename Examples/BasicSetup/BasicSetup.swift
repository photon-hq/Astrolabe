import ArgumentParser
import Astrolabe
import Foundation

/// A minimal Astrolabe configuration that installs a few Homebrew packages.
@main
struct BasicSetup: Astrolabe {
    @State var showDialog = false
    @Storage("message") var message = ""

    init() {
        Self.daemonMode = false
        Self.reset(.identities)
    }

    static var commands: [any AsyncParsableCommand.Type] { [Status.self] }

    func onStart() async throws {
        // let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
        // let brewPath = "/opt/homebrew/bin/brew"

        // for (name, flag) in [("firefox", "--cask"), ("htop", "--formula")] {
        //     let process = Process()
        //     process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        //     process.arguments = ["-u", user, brewPath, "uninstall", flag, name]
        //     process.standardOutput = FileHandle.nullDevice
        //     process.standardError = FileHandle.nullDevice
        //     try? process.run()
        //     process.waitUntilExit()
        // }
    }

    var body: some Setup {
        Pkg(.catalog(.homebrew))

        Brew("wget")
        Brew("jq")
        // Brew("firefox", type: .cask)
        //     .priority(1)
        // Brew("htop")
        //     .priority(0)

        Anchor()
            .task {
                // try? await Task.sleep(for: .seconds(2))
                self.showDialog = true
            }
            .dialog("Test Dialog", message: message, isPresented: $showDialog) {
                Button("OK") {
                    self.message = "Hi"
                    self.showDialog = false
                }

                Button("Not OK") {
                    self.message = "Not OK"
                    self.showDialog = false
                }
            }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print recorded payloads and current @Storage message."
    )

    func run() async throws {
        let payloads = AstrolabeState.payloads()
        if payloads.isEmpty {
            print("No payloads recorded.")
        } else {
            print("Payloads (\(payloads.count)):")
            for (identity, record) in payloads {
                print("  \(identity.path) → \(record)")
            }
        }
        let message: String? = AstrolabeState.storage("message", as: String.self)
        print("message: \(message ?? "<unset>")")
    }
}
