import Astrolabe
import Foundation

/// A minimal Astrolabe configuration that installs a few Homebrew packages.
@main
struct BasicSetup: Astrolabe {
    init() {
        Self.installDaemon = false
        
        // Clear persisted identities so every run starts fresh.
        try? FileManager.default.removeItem(at: Persistence.identitiesURL)
    }

    func onStart() async throws {
        let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
        let brewPath = "/opt/homebrew/bin/brew"

        for (name, flag) in [("firefox", "--cask"), ("htop", "--formula")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-u", user, brewPath, "uninstall", flag, name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    var body: some Setup {
        Pkg(.catalog(.homebrew))

        Brew("wget")
        Brew("jq")
        Brew("firefox", type: .cask)
        Brew("htop")
    }
}
