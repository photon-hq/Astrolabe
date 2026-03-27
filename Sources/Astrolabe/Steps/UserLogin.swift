import Foundation

/// A lifecycle trigger that waits for a user to log in,
/// then runs its child steps.
///
/// ```swift
/// UserLogin {
///     Dialog("Welcome") { Button("OK") }
/// }
/// ```
public struct UserLogin<Content: Setup>: Setup {
    public let content: Content

    public init(@SetupBuilder content: () -> Content) {
        self.content = content()
    }

    public func execute() async throws {
        while !hasConsoleUser() {
            try await Task.sleep(for: .seconds(5))
        }
        try await content.execute()
    }

    private func hasConsoleUser() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        process.arguments = ["-f", "%u", "/dev/console"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // UID 0 = root (loginwindow), no real user logged in
        guard let uid = Int(output) else { return false }
        return uid != 0
    }
}
