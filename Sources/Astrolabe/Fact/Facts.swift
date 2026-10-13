/// Every fact the engine reads from the Mac, by key. Like SwiftUI's `EnvironmentValues`.
///
/// Give each `FactKey` a key path in an extension, and read it in `body` with `@Fact`:
///
/// ```swift
/// extension Facts {
///     var stagingFiles: [String: String] { self[StagingFiles.self] }
///     var system: SystemFacts { SystemFacts(facts: self) }       // a namespace reads nothing by itself
/// }
///
/// struct SystemFacts {
///     let facts: Facts
///     var sipDisabled: Bool  { facts[SIPDisabled.self] }
///     var amfiDisabled: Bool { facts[AMFIDisabled.self] }
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
                assertionFailure("[Astrolabe] \(K.self) was read outside a pass. Read facts in `body` only.")
                return K.defaultValue
            }
            return store.value(of: K.self)
        }
    }
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
