import Foundation

/// Checks MDM enrollment status and updates `\.isEnrolled`.
public struct EnrollmentProvider: StateProvider {
    private let lastValue = LockedValue<Bool?>(nil)

    public init() {}

    public func check(updating environment: inout EnvironmentValues) -> Bool {
        let current = isEnrolled()
        environment.isEnrolled = current
        return lastValue.exchange(current)
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
        return output.contains("Yes (User Approved)")
            || output.contains("MDM enrollment: Yes")
    }
}
