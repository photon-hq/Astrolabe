/// A two-way reference to a mutable value.
///
/// Like SwiftUI's `Binding`, enables reading and writing a value
/// owned by another source of truth (typically `@State`).
@propertyWrapper
public struct Binding<Value: Sendable>: Sendable {
    private let getter: @Sendable () -> Value
    private let setter: @Sendable (Value) -> Void

    public var wrappedValue: Value {
        get { getter() }
        nonmutating set { setter(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    public init(get: @escaping @Sendable () -> Value, set: @escaping @Sendable (Value) -> Void) {
        self.getter = get
        self.setter = set
    }

    /// Creates a constant binding that never changes.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
}
