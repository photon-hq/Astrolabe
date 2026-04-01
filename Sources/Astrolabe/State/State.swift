import Foundation

/// Ephemeral local state that triggers body re-evaluation on mutation.
///
/// Like SwiftUI's `@State` — in-memory only, resets on daemon restart.
/// The framework watches for changes and re-evaluates the body.
///
/// ```swift
/// @State var showWelcome = true
/// ```
@propertyWrapper
public struct State<Value: Sendable>: Sendable {
    private let storage: StateStorage<Value>

    public var wrappedValue: Value {
        get { storage.value }
        nonmutating set {
            storage.value = newValue
            StateTracker.shared.notifyChange()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { storage.value },
            set: { newValue in
                storage.value = newValue
                StateTracker.shared.notifyChange()
            }
        )
    }

    public init(wrappedValue: Value) {
        self.storage = StateStorage(wrappedValue)
    }
}

/// Thread-safe storage for a `@State` value.
final class StateStorage<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Coordinates state change notifications between `@State` properties and the lifecycle engine.
public final class StateTracker: Sendable {
    public static let shared = StateTracker()

    private let _continuation: AsyncStream<Void>.Continuation
    public let changes: AsyncStream<Void>

    private init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.changes = stream
        self._continuation = continuation
    }

    func notifyChange() {
        _continuation.yield()
    }
}
