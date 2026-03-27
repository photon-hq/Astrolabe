/// A button displayed in a dialog.
///
/// ```swift
/// Button("Continue") {
///     print("User chose to continue")
/// }
/// ```
public struct Button: @unchecked Sendable {
    public let label: String
    public let action: @Sendable () async throws -> Void

    public init(_ label: String, action: @escaping @Sendable () async throws -> Void = {}) {
        self.label = label
        self.action = action
    }
}
