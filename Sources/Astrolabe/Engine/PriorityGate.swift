import Foundation

/// Coordinates priority-ordered task startup.
///
/// Each identity can signal "ready" (first install iteration done).
/// A coordinator awaits all signals in a priority group before
/// starting the next group's tasks.
public final class PriorityGate: @unchecked Sendable {
    public static let shared = PriorityGate()

    private let lock = NSLock()
    private var groups: [NodeIdentity: GroupSignal] = [:]

    public init() {}

    /// Registers an identity as part of a group signal.
    func register(_ identity: NodeIdentity, signal: GroupSignal) {
        lock.withLock { groups[identity] = signal }
    }

    /// Called by Installable task loops after their first iteration completes.
    public func markReady(_ identity: NodeIdentity) {
        let signal: GroupSignal? = lock.withLock {
            groups.removeValue(forKey: identity)
        }
        signal?.decrement()
    }
}

/// A countdown signal that resolves when all members have reported ready.
public final class GroupSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var continuation: CheckedContinuation<Void, Never>?

    public init(count: Int) {
        self.remaining = count
    }

    func decrement() {
        lock.withLock {
            remaining -= 1
            if remaining == 0 {
                continuation?.resume()
                continuation = nil
            }
        }
    }

    /// Suspends until all members have called `decrement()`.
    /// Returns immediately if already complete.
    func wait() async {
        let alreadyDone: Bool = lock.withLock { remaining <= 0 }
        if alreadyDone { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume: Bool = lock.withLock {
                if remaining <= 0 {
                    return true
                }
                continuation = cont
                return false
            }
            if shouldResume {
                cont.resume()
            }
        }
    }
}
