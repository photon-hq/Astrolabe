import Foundation

/// Presents a macOS list picker using AppleScript's `choose from list`.
///
/// Used internally by the reconciler when a `.listDialog()` modifier is active.
public struct ListDialog: Sendable {
    public let prompt: String
    public let items: [String]
    public let defaultItems: [String]
    public let multipleSelection: Bool

    public init(
        prompt: String,
        items: [String],
        defaultItems: [String] = [],
        multipleSelection: Bool = false
    ) {
        self.prompt = prompt
        self.items = items
        self.defaultItems = defaultItems
        self.multipleSelection = multipleSelection
    }

    /// Presents the list dialog and returns the selected items, or `nil` if cancelled.
    public func present() async throws -> [String]? {
        let script = buildScript()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output == "false" || output.isEmpty {
            return nil
        }

        return output.components(separatedBy: ", ")
    }

    // MARK: - Private

    func buildScript() -> String {
        let list = items.map { escaped($0) }.joined(separator: ", ")
        var parts = ["choose from list {\(list)}"]
        parts.append("with prompt \(escaped(prompt))")

        if !defaultItems.isEmpty {
            let defaults = defaultItems.map { escaped($0) }.joined(separator: ", ")
            parts.append("default items {\(defaults)}")
        }

        if multipleSelection {
            parts.append("with multiple selections allowed")
        }

        return parts.joined(separator: " ")
    }

    private func escaped(_ string: String) -> String {
        let inner = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(inner)\""
    }
}
