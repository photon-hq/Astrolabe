/// A provider that checks system state and updates environment values.
///
/// The engine polls all registered providers periodically. If any provider
/// returns `true` (indicating its value changed), the tree is re-evaluated.
///
/// ```swift
/// struct NetworkProvider: StateProvider {
///     let lastValue = LockedValue(false)
///
///     func check(updating environment: inout EnvironmentValues) -> Bool {
///         let current = checkNetwork()
///         environment.isOnline = current
///         return lastValue.exchange(current)
///     }
/// }
/// ```
public protocol StateProvider: Sendable {
    /// Checks system state and updates environment values.
    /// Returns `true` if the state changed since the last check.
    @discardableResult
    func check(updating environment: inout EnvironmentValues) -> Bool
}
