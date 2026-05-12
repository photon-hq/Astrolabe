import ArgumentParser
import Foundation

/// Public subcommand: print the most recent self-update activity.
///
/// ```
/// $ sudo mysetup update-status
/// Current version  : 1.2.3
/// Last checked     : 2026-05-12 14:30:00 +0000
/// Last seen version: 1.2.4
/// Last updated     : 2026-05-12 14:30:02 +0000
/// Last error       : -
/// ```
struct UpdateStatusCommand<App: Astrolabe>: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "update-status",
            abstract: "Show the most recent self-update activity."
        )
    }

    mutating func run() async throws {
        let status = AstrolabeState.updateStatus()
        let configured = App.update != nil

        print("Current version  : \(App.version)")
        print("Auto-update      : \(configured ? "configured" : "not configured")")
        print("Last checked     : \(format(status.lastCheckedAt))")
        print("Last seen version: \(status.lastSeenVersion ?? "-")")
        print("Last updated     : \(format(status.lastUpdatedAt))")
        print("Last error       : \(status.lastError ?? "-")")
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
