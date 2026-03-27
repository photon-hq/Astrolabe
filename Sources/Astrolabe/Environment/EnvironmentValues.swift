/// A collection of environment values propagated through the step tree.
///
/// Steps read values via `EnvironmentValues.current` during execution.
public struct EnvironmentValues: Sendable {
    @TaskLocal public static var current = EnvironmentValues()

    private var storage: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}
