import Foundation
@testable import Astrolabe

/// Stands in for the facts on the Mac. `FakeFactKey`s read it through `@TaskLocal`: fact loops
/// are started inside `engine.run()`, so they inherit it.
///
/// Holds a value per key, can hold a key's reads until released, can fail them on command, and
/// counts them.
final class FakeFacts: @unchecked Sendable {
    @TaskLocal static var current: FakeFacts?

    struct FakeError: Error {}
    /// The key has no value on the fake Mac.
    struct Unset: Error {}

    private let lock = NSLock()
    private var values: [ObjectIdentifier: any Sendable] = [:]
    private var injectors: [ObjectIdentifier: @MainActor @Sendable (FactStore) -> Void] = [:]
    private var blocked: Set<ObjectIdentifier> = []
    private var failures: [ObjectIdentifier: Int] = [:]
    private var readCounts: [ObjectIdentifier: Int] = [:]

    // MARK: - Values

    /// Puts `value` on the fake Mac. The next read of `key` returns it; nothing is injected.
    func set<K: FactKey>(_ key: K.Type, _ value: K.Value) {
        lock.withLock {
            values[ObjectIdentifier(key)] = value
            injectors[ObjectIdentifier(key)] = { $0.inject(K.self, value) }
        }
    }

    func value<K: FactKey>(_ key: K.Type) -> K.Value? {
        lock.withLock { values[ObjectIdentifier(key)] as? K.Value }
    }

    /// Injects every value set so far into `store`, as if each had just been read.
    @MainActor
    func inject(into store: FactStore) {
        for injector in lock.withLock({ Array(injectors.values) }) {
            injector(store)
        }
    }

    // MARK: - Control

    /// Holds every read of `key` until `release(key)`. A held read still ends early with
    /// `CancellationError` when cancelled.
    func block<K: FactKey>(_ key: K.Type) { _ = lock.withLock { blocked.insert(ObjectIdentifier(key)) } }
    func release<K: FactKey>(_ key: K.Type) { _ = lock.withLock { blocked.remove(ObjectIdentifier(key)) } }

    /// The next `times` reads of `key` throw `FakeError`.
    func fail<K: FactKey>(_ key: K.Type, times: Int = 1) {
        lock.withLock { failures[ObjectIdentifier(key), default: 0] += times }
    }

    // MARK: - Inspection

    /// Reads of `key` started so far, including held and failed ones.
    func reads<K: FactKey>(_ key: K.Type) -> Int { lock.withLock { readCounts[ObjectIdentifier(key)] ?? 0 } }

    var blockedKeys: Set<ObjectIdentifier> { lock.withLock { blocked } }

    // MARK: - Reads

    static func read<K: FactKey>(_ key: K.Type) async throws -> K.Value {
        guard let facts = current else {
            fatalError("\(K.self) read outside FakeFacts.$current.withValue")
        }
        return try await facts.read(key)
    }

    private func read<K: FactKey>(_ key: K.Type) async throws -> K.Value {
        let id = ObjectIdentifier(key)
        lock.withLock { readCounts[id, default: 0] += 1 }
        while lock.withLock({ blocked.contains(id) }) {
            try Task.checkCancellation()
            await realSleep(.milliseconds(1))
        }
        try Task.checkCancellation()
        let (shouldFail, value) = lock.withLock { () -> (Bool, (any Sendable)?) in
            guard let remaining = failures[id], remaining > 0 else { return (false, values[id]) }
            failures[id] = remaining - 1
            return (true, nil)
        }
        if shouldFail { throw FakeError() }
        guard let value, let typed = value as? K.Value else { throw Unset() }
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
