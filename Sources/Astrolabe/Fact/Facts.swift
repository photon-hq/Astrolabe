/// Every fact the engine reads from the Mac, by key. Like SwiftUI's `EnvironmentValues`.
///
/// Declare each fact in an extension with `@FactEntry`, or give a hand-written `FactKey` a key
/// path, and read it in `body` with `@Fact`:
///
/// ```swift
/// extension Facts {
///     @FactEntry(schedule: .every(.seconds(1)), read: { try StateFile.read(StateFile.path) })
///     var stagingFiles: [String: String] = [:]
///
///     var inventory: Inventory? { self[InventoryKey.self] }       // a hand-written key
///     var system: SystemFacts { SystemFacts(facts: self) }       // a namespace reads nothing by itself
/// }
///
/// struct SystemFacts: FactNamespace {
///     let facts: Facts
///
///     @FactEntry(read: { try await CSR.sipDisabled() })
///     var sipDisabled: Bool = false
///
///     var amfiDisabled: Bool { self[AMFIDisabled.self] }
///     var readyForPackages: Bool { sipDisabled && amfiDisabled }  // tracked through both
/// }
/// ```
///
/// Only subscripting with a key is tracked: the pass that reads it depends on it, and a change
/// to it runs the next pass. Read facts only while `body` is evaluated.
public struct Facts: Sendable {
    /// The engine's store while a pass evaluates `body`; `nil` outside one.
    let store: FactStore?

    init(store: FactStore?) {
        self.store = store
    }

    /// The fact's last value read from the Mac, or `K.defaultValue` before the first read lands.
    public subscript<K: FactKey>(_ key: K.Type) -> K.Value {
        MainActor.assumeIsolated { [store] in
            guard let store else {
                assertionFailure("[Astrolabe] \(K.factName) was read outside a pass. Read facts in `body` only.")
                return K.defaultValue
            }
            return store.value(of: K.self)
        }
    }
}

/// A group of facts under one key path, like `\.system.sipDisabled`. Reads nothing by itself.
///
/// Holds the `Facts` it was made from, and subscripts them the same way, so `@FactEntry` works
/// inside it as it does in an `extension Facts`.
public protocol FactNamespace {
    var facts: Facts { get }
}

extension FactNamespace {
    /// Tracked like `Facts`' subscript: it forwards to it.
    public subscript<K: FactKey>(_ key: K.Type) -> K.Value { facts[key] }
}

/// Reads a fact in `body`. Like SwiftUI's `@Environment`.
///
/// ```swift
/// @main
/// struct StagingApp: Astrolabe {
///     @Fact(\.stagingFiles) var files
///
///     var body: some Component {
///         for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
///             StagingFile(path: "\(StateFile.directory)/\(name)", contents: contents)
///         }
///     }
/// }
/// ```
///
/// The first pass that reads a fact starts reading it from the Mac. Until that read lands the
/// value is the key's `defaultValue`, and the engine acts on nothing.
@MainActor @propertyWrapper
public struct Fact<Value> {
    private let keyPath: KeyPath<Facts, Value>

    public init(_ keyPath: KeyPath<Facts, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        Facts(store: FactStore.current)[keyPath: keyPath]
    }
}
