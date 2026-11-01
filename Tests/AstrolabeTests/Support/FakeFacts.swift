import Foundation
@testable import Astrolabe

/// Stands in for the facts on the Mac. `FakeFactKey`s and `@FactEntry` facts read it through
/// `@TaskLocal`: fact loops are started inside `engine.run()`, so they inherit it.
///
/// Holds a value per fact, can hold a fact's reads until released, can fail them on command, and
/// counts them. A fact is a key type, or a name an `@FactEntry` read passes:
/// `read: { try await FakeFacts.read("left", as: Bool.self) }`.
final class FakeFacts: @unchecked Sendable {
    @TaskLocal static var current: FakeFacts?

    struct FakeError: Error {}
    /// The fact has no value on the fake Mac.
    struct Unset: Error {}

    private let lock = NSLock()
    /// Keyed by `ObjectIdentifier` for a key type, by `String` for a name.
    private var values: [AnyHashable: any Sendable] = [:]
    private var injectors: [ObjectIdentifier: @MainActor @Sendable (FactStore) -> Void] = [:]
    private var blocked: Set<AnyHashable> = []
    private var failures: [AnyHashable: Int] = [:]
    private var readCounts: [AnyHashable: Int] = [:]
    private var held = 0

    // MARK: - Values

    /// Puts `value` on the fake Mac. The next read of `key` returns it; nothing is injected.
    func set<K: FactKey>(_ key: K.Type, _ value: K.Value) {
        lock.withLock {
            values[ObjectIdentifier(key)] = value
            injectors[ObjectIdentifier(key)] = { $0.inject(K.self, value) }
        }
    }

    /// Puts `value` on the fake Mac for the fact that reads `name`. Never injected by
    /// `inject(into:)`, which can't name its key: a pass reads it.
    func set(_ name: String, _ value: some Sendable) {
        lock.withLock { values[name] = value }
    }

    func value<K: FactKey>(_ key: K.Type) -> K.Value? {
        lock.withLock { values[ObjectIdentifier(key)] as? K.Value }
    }

    /// Injects every key's value set so far into `store`, as if each had just been read.
    @MainActor
    func inject(into store: FactStore) {
        for injector in lock.withLock({ Array(injectors.values) }) {
            injector(store)
        }
    }

    // MARK: - Control

    /// Holds every read of `key` until `release(key)`. A held read still ends early with
    /// `CancellationError` when cancelled.
    func block<K: FactKey>(_ key: K.Type) { block(id: ObjectIdentifier(key)) }
    func block(_ name: String) { block(id: name) }
    func release<K: FactKey>(_ key: K.Type) { release(id: ObjectIdentifier(key)) }
    func release(_ name: String) { release(id: name) }

    /// The next `times` reads of `key` throw `FakeError`.
    func fail<K: FactKey>(_ key: K.Type, times: Int = 1) { fail(id: ObjectIdentifier(key), times: times) }
    func fail(_ name: String, times: Int = 1) { fail(id: name, times: times) }

    private func block(id: AnyHashable) { _ = lock.withLock { blocked.insert(id) } }
    private func release(id: AnyHashable) { _ = lock.withLock { blocked.remove(id) } }
    private func fail(id: AnyHashable, times: Int) { lock.withLock { failures[id, default: 0] += times } }

    // MARK: - Inspection

    /// Reads of `key` started so far, including held and failed ones.
    func reads<K: FactKey>(_ key: K.Type) -> Int { reads(id: ObjectIdentifier(key)) }
    func reads(_ name: String) -> Int { reads(id: name) }

    private func reads(id: AnyHashable) -> Int { lock.withLock { readCounts[id] ?? 0 } }

    /// Reads held by `block` right now.
    var heldReads: Int { lock.withLock { held } }

    // MARK: - Reads

    static func read<K: FactKey>(_ key: K.Type) async throws -> K.Value {
        try await current("\(K.self)").read(id: ObjectIdentifier(key), as: K.Value.self)
    }

    /// The read of an `@FactEntry` fact. `as` names the type: the macro's argument can't infer it.
    static func read<Value: Sendable>(_ name: String, as _: Value.Type) async throws -> Value {
        try await current(name).read(id: name, as: Value.self)
    }

    private static func current(_ fact: String) -> FakeFacts {
        guard let current else {
            fatalError("\(fact) read outside FakeFacts.$current.withValue")
        }
        return current
    }

    private func read<Value>(id: AnyHashable, as _: Value.Type) async throws -> Value {
        lock.withLock { readCounts[id, default: 0] += 1 }
        if lock.withLock({ blocked.contains(id) }) {
            lock.withLock { held += 1 }
            defer { lock.withLock { held -= 1 } }
            while lock.withLock({ blocked.contains(id) }) {
                try Task.checkCancellation()
                await realSleep(.milliseconds(1))
            }
        }
        try Task.checkCancellation()
        let (shouldFail, value) = lock.withLock { () -> (Bool, (any Sendable)?) in
            guard let remaining = failures[id], remaining > 0 else { return (false, values[id]) }
            failures[id] = remaining - 1
            return (true, nil)
        }
        if shouldFail { throw FakeError() }
        guard let value, let typed = value as? Value else { throw Unset() }
        return typed
    }
}

/// A fact key that reads the task-local `FakeFacts`.
protocol FakeFactKey: FactKey {}

extension FakeFactKey {
    @concurrent static func read() async throws -> Value {
        try await FakeFacts.read(Self.self)
    }
}

// MARK: - TestApp's facts

/// Everything `TestApp` declares, as one fact.
struct TestValues: Equatable, Sendable {
    var retry: [RetryFake] = []
    var rollback: [RollbackFake] = []
    var wait: [WaitFake] = []
    var capped: [CappedFake] = []
    /// Read by `body` without affecting what it declares.
    var tracked = 0
}

struct TestValuesKey: FakeFactKey {
    static let defaultValue = TestValues()
}

/// Never read by `body`: a change to it must not wake the engine.
struct UntrackedKey: FakeFactKey {
    static let defaultValue = 0
}

extension Facts {
    var test: TestValues { self[TestValuesKey.self] }
    var untracked: Int { self[UntrackedKey.self] }
}

/// `h.state`: each write puts the value on the fake Mac and injects it, synchronously, as if it
/// had just been read.
@MainActor
struct TestState {
    let fakeFacts: FakeFacts
    let facts: FactStore

    var retry: [RetryFake] {
        get { values.retry }
        nonmutating set { update { $0.retry = newValue } }
    }

    var rollback: [RollbackFake] {
        get { values.rollback }
        nonmutating set { update { $0.rollback = newValue } }
    }

    var wait: [WaitFake] {
        get { values.wait }
        nonmutating set { update { $0.wait = newValue } }
    }

    var capped: [CappedFake] {
        get { values.capped }
        nonmutating set { update { $0.capped = newValue } }
    }

    var tracked: Int {
        get { values.tracked }
        nonmutating set { update { $0.tracked = newValue } }
    }

    var untracked: Int {
        get { fakeFacts.value(UntrackedKey.self) ?? 0 }
        nonmutating set {
            fakeFacts.set(UntrackedKey.self, newValue)
            facts.inject(\.untracked, newValue)
        }
    }

    private var values: TestValues {
        fakeFacts.value(TestValuesKey.self) ?? TestValues()
    }

    private func update(_ change: (inout TestValues) -> Void) {
        var values = self.values
        change(&values)
        fakeFacts.set(TestValuesKey.self, values)
        facts.inject(\.test, values)
    }
}
