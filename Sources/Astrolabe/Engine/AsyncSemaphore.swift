import Foundation

/// A simple async semaphore for serializing operations.
///
/// Unlike `NSLock`, safe to hold across `await` suspension points.
/// Used to serialize brew operations which cannot run in parallel.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until the semaphore is available, then acquires it.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if available {
                    available = false
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    /// Releases the semaphore, resuming the next waiter if any.
    func signal() {
        lock.withLock {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                available = true
            }
        }
    }
}
