import Foundation

/// Persistent local state that survives daemon restart.
///
/// Like SwiftUI's `@AppStorage`, but accepts any `Codable` value. Values are
/// stored in the `StorageStore`, keyed by an explicit string key provided at
/// declaration. Mutations trigger body re-evaluation only when the value changes.
///
/// ```swift
/// @Storage("hasCompletedOnboarding") var hasCompletedOnboarding = false
/// ```
@propertyWrapper
public struct Storage<Value: Codable & Equatable & Sendable>: Sendable, _StateProperty {
    private let handle: StorageHandle<Value>

    public init(wrappedValue: Value, _ key: String) {
        self.handle = StorageHandle(key: key, defaultValue: wrappedValue)
    }

    public var wrappedValue: Value {
        get { handle.get() }
        nonmutating set { handle.set(newValue) }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { handle.get() },
            set: { handle.set($0) }
        )
    }

    func _connect(path: NodeIdentity, slot: String) {
        // No-op. @Storage uses explicit string keys, not position-keyed slots.
        // Conformance to _StateProperty keeps the discovery pattern uniform.
    }
}

/// Reference-type backing for `@Storage`. Routes reads/writes through `StorageStore`.
///
/// Unlike `StateHandle`, the key is known at init — no `connect` call needed.
final class StorageHandle<Value: Codable & Equatable & Sendable>: @unchecked Sendable {
    private let key: String
    private let defaultValue: Value

    init(key: String, defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    func get() -> Value {
        StorageStore.shared.get(key, default: defaultValue)
    }

    func set(_ newValue: Value) {
        if StorageStore.shared.set(key, value: newValue) {
            StateNotifier.shared.notifyChange()
        }
    }
}
