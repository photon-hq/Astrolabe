/// A modifier that invokes a callback before unmount (uninstall).
public struct PreUninstallModifier: SetupModifier, @unchecked Sendable {
    public let handler: @Sendable () async throws -> Void

    public init(handler: @escaping @Sendable () async throws -> Void) {
        self.handler = handler
    }
}

extension Installable {
    /// Runs an async closure immediately before this declaration is uninstalled.
    /// Errors are logged but do not block the uninstall.
    public func preUninstall(
        _ handler: @escaping @Sendable () async throws -> Void
    ) -> ModifiedContent<Self, PreUninstallModifier> {
        ModifiedContent(content: self, modifier: PreUninstallModifier(handler: handler))
    }
}
