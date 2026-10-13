import Foundation
@testable import Astrolabe

/// Stands in for the Mac. `FakeResource` reaches it through `@TaskLocal`: op tasks are created
/// inside `engine.run()`, so they inherit it.
///
/// Records every call, can hold an id's operations until released, can throw on command, and
/// tracks what is "on the Mac" after each operation that returns.
final class FakeMachine: @unchecked Sendable {
    @TaskLocal static var current: FakeMachine?

    enum Op: String, Sendable { case rollout, remove }

    struct Call: Equatable, Sendable {
        let op: Op
        let id: String
        let value: String
    }

    enum Ending: Equatable, Sendable {
        case returned
        case cancelled
        case threw
    }

    struct FakeError: Error {}

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _endings: [(Call, Ending)] = []
    private var _state: [String: String] = [:]
    private var blocked: Set<String> = []
    private var ignoringCancel: Set<String> = []
    private var failures: [String: Int] = [:]
    private var active: [String: Int] = [:]
    private var _maxActivePerID = 0
    private var _maxActiveTotal = 0

    // MARK: - Inspection

    var calls: [Call] { lock.withLock { _calls } }
    var endings: [(call: Call, ending: Ending)] { lock.withLock { _endings.map { ($0.0, $0.1) } } }
    /// What each id looks like on the "Mac" after the last operation that returned.
    var state: [String: String] { lock.withLock { _state } }
    /// Operations currently running, per id and in total.
    func activeCount(_ id: String) -> Int { lock.withLock { active[id] ?? 0 } }
    var activeTotal: Int { lock.withLock { active.values.reduce(0, +) } }
    /// Never more than one operation per id may run at once.
    var maxActivePerID: Int { lock.withLock { _maxActivePerID } }
    var maxActiveTotal: Int { lock.withLock { _maxActiveTotal } }

    func calls(_ id: String) -> [Call] { calls.filter { $0.id == id } }

    // MARK: - Control

    /// Holds every operation on `id` until `release(id)`. A held operation still ends early
    /// with `CancellationError` when cancelled, unless `ignoreCancel(id)` was called.
    func block(_ id: String) { _ = lock.withLock { blocked.insert(id) } }
    func release(_ id: String) { _ = lock.withLock { blocked.remove(id) } }

    /// Held operations on `id` keep running through a cancel until released, then throw
    /// `CancellationError` — a cooperative but slow operation. Combined with never releasing,
    /// a wedged one.
    func ignoreCancel(_ id: String) { _ = lock.withLock { ignoringCancel.insert(id) } }

    /// The next `times` operations on `id` throw `FakeError` instead of acting.
    func fail(_ id: String, times: Int = 1) { lock.withLock { failures[id, default: 0] += times } }

    /// Puts `value` on the Mac for `id` without an operation.
    func preset(_ id: String, _ value: String?) { lock.withLock { _state[id] = value } }

    // MARK: - Operations

    func perform(_ op: Op, id: String, value: String) async throws {
        let call = Call(op: op, id: id, value: value)
        lock.withLock {
            _calls.append(call)
            active[id, default: 0] += 1
            _maxActivePerID = max(_maxActivePerID, active[id]!)
            _maxActiveTotal = max(_maxActiveTotal, active.values.reduce(0, +))
        }

        let ending: Ending
        do {
            try await act(call)
            ending = .returned
        } catch is CancellationError {
            ending = .cancelled
            finish(call, ending)
            throw CancellationError()
        } catch {
            ending = .threw
            finish(call, ending)
            throw error
        }
        finish(call, ending)
    }

    private func act(_ call: Call) async throws {
        while isBlocked(call.id) {
            if Task.isCancelled, !ignoresCancel(call.id) { throw CancellationError() }
            await realSleep(.milliseconds(1))
        }
        try Task.checkCancellation()
        let shouldFail = lock.withLock { () -> Bool in
            guard let remaining = failures[call.id], remaining > 0 else { return false }
            failures[call.id] = remaining - 1
            return true
        }
        if shouldFail { throw FakeError() }
        lock.withLock {
            switch call.op {
            case .rollout: _state[call.id] = call.value
            case .remove: _state[call.id] = nil
            }
        }
    }

    private func finish(_ call: Call, _ ending: Ending) {
        lock.withLock {
            active[call.id, default: 1] -= 1
            _endings.append((call, ending))
        }
    }

    private func isBlocked(_ id: String) -> Bool { lock.withLock { blocked.contains(id) } }
    private func ignoresCancel(_ id: String) -> Bool { lock.withLock { ignoringCancel.contains(id) } }
}

/// Sleeps on the wall clock, ignoring cancellation, so a polling loop never spins.
func realSleep(_ duration: Duration) async {
    let (seconds, attoseconds) = duration.components
    let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
            continuation.resume()
        }
    }
}
