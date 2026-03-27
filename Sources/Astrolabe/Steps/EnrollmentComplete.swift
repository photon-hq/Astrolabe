import Foundation

/// A lifecycle trigger that waits for MDM enrollment to complete,
/// then runs its child steps.
///
/// ```swift
/// EnrollmentComplete {
///     PackageInstaller(.jamf(trigger: "installCLITools"))
/// }
/// ```
public struct EnrollmentComplete<Content: Setup>: Setup {
    public let content: Content

    public init(@SetupBuilder content: () -> Content) {
        self.content = content()
    }

    public func execute() async throws {
        while !isEnrolled() {
            try await Task.sleep(for: .seconds(5))
        }
        try await content.execute()
    }

    private func isEnrolled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
        process.arguments = ["status", "-type", "enrollment"]

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
        let output = String(data: data, encoding: .utf8) ?? ""
        // Output contains "MDM enrollment: Yes" when enrolled
        return output.contains("Yes (User Approved)")
            || output.contains("MDM enrollment: Yes")
    }
}
