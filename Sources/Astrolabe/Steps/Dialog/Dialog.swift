import Foundation

/// Presents a macOS dialog using NSAlert via the AppleScript-ObjC bridge.
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

    /// Internal init for constructing from pre-built button arrays (used by the Reconciler).
    init(_ title: String, message: String, buttons: [Button]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }

    public func present() async throws {
        let ordered = orderedButtons()
        guard !ordered.isEmpty else { return }

        let script = buildNSAlertScript(buttons: ordered)

        try await LaunchctlHelper.waitForGUISession()

        let (status, output) = LaunchctlHelper.runOsascript(
            arguments: ["-l", "AppleScript", "-e", script]
        )

        guard status == 0 else {
            throw DialogError.cancelled
        }

        // The script returns the 0-based index of the pressed button.
        if let pressedIndex = Int(output),
           pressedIndex >= 0, pressedIndex < ordered.count {
            try await ordered[pressedIndex].action()
        }
    }

    // MARK: - Private

    /// Orders buttons following macOS HIG: primary first, destructive near end, cancel last.
    func orderedButtons() -> [Button] {
        var primary: [Button] = []
        var destructive: [Button] = []
        var cancel: Button?

        for button in buttons {
            switch button.role {
            case .none:
                primary.append(button)
            case .destructive:
                destructive.append(button)
            case .cancel:
                cancel = button
            }
        }

        var result = primary + destructive
        if let cancel { result.append(cancel) }
        return result
    }

    /// Builds an AppleScript that uses the ObjC bridge to create an NSAlert.
    private func buildNSAlertScript(buttons ordered: [Button]) -> String {
        let defaultIndex = ordered.firstIndex(where: { $0.role == nil }) ?? 0

        var lines: [String] = []
        lines.append("use framework \"AppKit\"")
        lines.append("use scripting additions")
        lines.append("")
        lines.append("set theAlert to current application's NSAlert's alloc()'s init()")
        lines.append("theAlert's setMessageText:\(escaped(title))")
        lines.append("theAlert's setInformativeText:\(escaped(message))")

        for (i, button) in ordered.enumerated() {
            lines.append("set btn\(i) to (theAlert's addButtonWithTitle:\(escaped(button.label)))")
            if button.role == .destructive {
                lines.append("btn\(i)'s setHasDestructiveAction:true")
            }
            if i == defaultIndex {
                lines.append("btn\(i)'s setKeyEquivalent:\"\\r\"")
            }
        }

        // NSAlert returns NSAlertFirstButtonReturn (1000) for the first added button,
        // 1001 for the second, etc.
        lines.append("set response to theAlert's runModal()")
        lines.append("set buttonIndex to (response as integer) - 1000")
        lines.append("return buttonIndex as text")

        return lines.joined(separator: "\n")
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
