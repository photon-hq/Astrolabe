/// A provider that checks system state and updates environment values.
///
/// The registry polls all registered providers each tick. If any value changes,
/// the body is re-evaluated.
///
/// ```swift
/// struct NetworkProvider: StateProvider {
///     func check(updating environment: inout EnvironmentValues) {
///         environment.isOnline = checkNetwork()
///     }
/// }
/// ```
public protocol StateProvider: Sendable {
    func check(updating environment: inout EnvironmentValues)
}
