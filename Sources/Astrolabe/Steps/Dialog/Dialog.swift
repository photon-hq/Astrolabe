import Foundation

/// Presents a macOS dialog using AppleScript.
///
/// Used internally by the reconciler when a `.dialog()` modifier is active.
public struct Dialog: Sendable {
    public let title: String
    public let message: String
    public let buttons: [Button]

    public init(
        _ title: String,
        message: String = "",
        @ButtonBuilder buttons: () -> [Button]
    ) {
        self.title = title
        self.message = message
        self.buttons = buttons()
    }

    public func present() async throws {
        var parts = [
            "display dialog \(escaped(message))",
            "with title \(escaped(title))",
        ]

        if !buttons.isEmpty {
            let list = buttons.map { escaped($0.label) }.joined(separator: ", ")
            parts.append("buttons {\(list)}")
            parts.append("default button \(escaped(buttons[0].label))")
        }

        let script = parts.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DialogError.cancelled
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if let range = output.range(of: "button returned:") {
            let pressed = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let button = buttons.first(where: { $0.label == pressed }) {
                try await button.action()
            }
        }
    }

    private func escaped(_ string: String) -> String {
        let inner = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(inner)\""
    }
}

public enum DialogError: Error, Sendable {
    case cancelled
}
