import Foundation

/// A fact's value, type-erased. Compared through a generic opener, like `AnyResource.hash`.
struct AnyFactValue: Equatable, Sendable {
    let base: any Equatable & Sendable

    init(_ base: some Equatable & Sendable) {
        self.base = base
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        equal(lhs.base, rhs.base)
    }

    private static func equal<V: Equatable & Sendable>(_ lhs: V, _ rhs: any Equatable & Sendable) -> Bool {
        lhs == (rhs as? V)
    }
}

/// The engine's facts: each key's last value, and the loop that reads it from the Mac.
///
/// The only arrow is fact → engine. A loop stores what it read; a first value, or one that
/// differs from the stored one, wakes the engine if the last pass read that key. The engine
/// never asks for a read, so operations ending or passes running never cause one.
///
/// Values are stored on the main actor and passes are synchronous there, so a value lands
/// either before a pass, which sees it, or after it, which wakes the next pass.
@MainActor
final class FactStore {
    /// The store whose pass is evaluating `body`, for `@Fact`. A main-actor static rather than a
    /// task-local, so operation and read tasks never inherit it.
    static var current: FactStore?

    private struct Entry {
        /// The key's name, for logs: `FactKey.factName`.
        let name: String
        let schedule: FactSchedule
        let timeout: Duration
        let read: @Sendable () async throws -> AnyFactValue
        /// Erases a value given to `inject`, if it is this key's `Value`.
        let erase: (Any) -> AnyFactValue?
        /// The last value read, or `nil` before the first.
        var value: AnyFactValue?
        /// Started by the first pass that reads the key; cancelled only at shutdown.
        var loop: Task<Void, Never>?

        init<K: FactKey>(_: K.Type) {
            name = K.factName
            schedule = K.schedule
            timeout = K.timeout
            read = { AnyFactValue(try await K.read()) }
            erase = { ($0 as? K.Value).map(AnyFactValue.init) }
        }
    }

    private let wake: Wake
    private let clock: EngineClock
    private let telemetry: any AstrolabeTelemetry
    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Keys read by the evaluation in progress; `nil` outside one.
    private var reads: Set<ObjectIdentifier>?
    /// Keys the last pass read. Only a change to one of them wakes the engine.
    private(set) var lastRead: Set<ObjectIdentifier> = []
    /// A change since the last pass already woke the engine. Like observation, a burst of
    /// changes wakes it once: the pass it runs sees them all.
    private var signalled = false
    /// Keys whose read is in flight. Tests use it to tell when the facts are quiet.
    private(set) var reading: Set<ObjectIdentifier> = []
    private var stopped = false

    init(wake: Wake, clock: EngineClock, telemetry: any AstrolabeTelemetry) {
        self.wake = wake
        self.clock = clock
        self.telemetry = telemetry
    }

    /// Evaluates `body`, recording each key it reads, then starts the loop of every key read for
    /// the first time.
    ///
    /// - Returns: what `body` returned, and the names of the keys it read that have no value yet.
    func tracking<T>(_ body: () -> T) -> (T, atDefault: [String]) {
        precondition(reads == nil, "[Astrolabe] a pass started while another was evaluating")
        reads = []
        Self.current = self
        let result = body()
        Self.current = nil
        let read = reads ?? []
        reads = nil

        lastRead = read
        signalled = false
        for id in read {
            startLoop(id)
        }
        let atDefault = read.compactMap { id in entries[id].flatMap { $0.value == nil ? $0.name : nil } }
        return (result, atDefault.sorted())
    }

    /// What `body` sees for `K`: its last value read, or its default before the first.
    func value<K: FactKey>(of key: K.Type) -> K.Value {
        let id = ObjectIdentifier(key)
        if entries[id] == nil {
            entries[id] = Entry(key)
        }
        if reads == nil {
            assertionFailure("[Astrolabe] \(K.factName) was read outside a pass. Read facts in `body` only.")
        }
        reads?.insert(id)
        return entries[id]?.value?.base as? K.Value ?? K.defaultValue
    }

    /// Stores a value read from the Mac. A first value, or one that differs from the stored one,
    /// wakes the engine if the last pass read the key; an equal one changes nothing.
    func store(_ id: ObjectIdentifier, _ value: AnyFactValue) {
        guard var entry = entries[id], entry.value != value else { return }
        entry.value = value
        entries[id] = entry
        if lastRead.contains(id), !signalled {
            signalled = true
            wake.signal()
        }
    }

    /// Tests only: stores `value` as if it had just been read, synchronously.
    ///
    /// `keyPath` must end at exactly one key, and `value` must be that key's `Value`:
    /// `\.system.sipDisabled` works, `\.system.readyForPackages` traps.
    func inject<V>(_ keyPath: KeyPath<Facts, V>, _ value: V) {
        let (_, captured) = capture(keyPath)
        guard captured.count == 1, let id = captured.first, let entry = entries[id] else {
            notOneKey(keyPath, reads: captured)
        }
        guard let erased = entry.erase(value) else {
            preconditionFailure("[Astrolabe] inject(\(keyPath)): \(V.self) is not the value of \(entry.name)")
        }
        store(id, erased)

        // A derived key path can read a single key while it short-circuits on a default, as
        // `sipDisabled && amfiDisabled` does: reading it back catches that.
        let (readBack, again) = capture(keyPath)
        guard again == captured, entry.erase(readBack) == erased else {
            notOneKey(keyPath, reads: captured.union(again))
        }
    }

    /// Tests only: stores `value` for `key` as if it had just been read.
    func inject<K: FactKey>(_ key: K.Type, _ value: K.Value) {
        let id = ObjectIdentifier(key)
        if entries[id] == nil {
            entries[id] = Entry(key)
        }
        store(id, AnyFactValue(value))
    }

    /// Cancels every loop, at shutdown. A read in flight is abandoned.
    func stopAll() {
        stopped = true
        for entry in entries.values {
            entry.loop?.cancel()
        }
    }

    /// Evaluates `keyPath` outside a pass, recording the keys it reads.
    private func capture<V>(_ keyPath: KeyPath<Facts, V>) -> (V, Set<ObjectIdentifier>) {
        precondition(reads == nil, "[Astrolabe] inject(\(keyPath)) during a pass")
        reads = []
        let value = Facts(store: self)[keyPath: keyPath]
        let captured = reads ?? []
        reads = nil
        return (value, captured)
    }

    private func notOneKey(_ keyPath: AnyKeyPath, reads: Set<ObjectIdentifier>) -> Never {
        let names = reads.compactMap { entries[$0]?.name }.sorted()
        preconditionFailure(
            "[Astrolabe] inject(\(keyPath)) must end at exactly one key; it reads \(names.isEmpty ? "none" : names.joined(separator: ", "))"
        )
    }

    // MARK: - Loops

    func readStarted(_ id: ObjectIdentifier) {
        reading.insert(id)
    }

    func readSucceeded(_ id: ObjectIdentifier, _ value: AnyFactValue) {
        reading.remove(id)
        store(id, value)
    }

    /// Keeps the last value. Only the first failure in a row is logged.
    func readFailed(_ id: ObjectIdentifier, _ error: any Error, inARow failures: Int) {
        reading.remove(id)
        guard failures == 1, let entry = entries[id] else { return }
        let hasValue = entry.value != nil
        let attributes = TelemetryAttributes.factReadFailedAttributes(
            fact: entry.name, hasValue: hasValue, error: error, verbose: telemetry.verboseNodeAttributes
        )
        telemetry.log(hasValue ? .warning : .error, "astrolabe.fact.read_failed", attributes: attributes)
        let consequence = hasValue ? "keeping its last value" : "passes that read it wait for its first value"
        print("[Astrolabe] reading \(entry.name) failed: \(error); \(consequence), retrying with backoff")
    }

    private func startLoop(_ id: ObjectIdentifier) {
        guard !stopped, let entry = entries[id], entry.loop == nil else { return }
        let loop = FactLoop(
            id: id, schedule: entry.schedule, timeout: entry.timeout, read: entry.read, clock: clock, store: self
        )
        // In flight from now, so tests never see the facts quiet before the loop's first read.
        readStarted(id)
        entries[id]?.loop = Task { await loop.run() }
    }
}
