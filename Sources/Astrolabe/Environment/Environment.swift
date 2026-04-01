/// A read-only property wrapper that reads a value from the environment.
///
/// ```swift
/// struct MySetup: Setup {
///     @Environment(\.isEnrolled) var isEnrolled
///
///     var body: some Setup {
///         if isEnrolled {
///             Brew("managed-tool")
///         }
///     }
/// }
/// ```
@propertyWrapper
public struct Environment<Value: Sendable>: @unchecked Sendable {
    private let keyPath: KeyPath<EnvironmentValues, Value>

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        EnvironmentValues.current[keyPath: keyPath]
    }
}
