/// Defines a key for storing values in the environment.
///
/// ```swift
/// struct MyKey: EnvironmentKey {
///     static let defaultValue: String = ""
/// }
/// ```
public protocol EnvironmentKey {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}
