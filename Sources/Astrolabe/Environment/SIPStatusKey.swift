import Foundation

/// Environment key for System Integrity Protection status.
struct SIPStatusKey: EnvironmentKey {
    static let defaultValue: Bool = Self.checkSIPEnabled()

    private static func checkSIPEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return true
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return output.contains("enabled")
    }
}

extension EnvironmentValues {
    /// Whether System Integrity Protection is enabled.
    public var isSIPEnabled: Bool {
        self[SIPStatusKey.self]
    }
}
