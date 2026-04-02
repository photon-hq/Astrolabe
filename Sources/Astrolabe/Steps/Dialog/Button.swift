/// A button displayed in a dialog.
///
/// ```swift
/// Button("Continue") {
///     print("User chose to continue")
/// }
///
/// Button("Delete", role: .destructive) {
///     deleteAllData()
/// }
///
/// Button("Cancel", role: .cancel)
/// ```
public struct Button: @unchecked Sendable {
    public let label: String
    public let role: ButtonRole?
    public let action: @Sendable () async throws -> Void

    public init(
        _ label: String,
        role: ButtonRole? = nil,
        action: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.label = label
        self.role = role
        self.action = action
    }
}
