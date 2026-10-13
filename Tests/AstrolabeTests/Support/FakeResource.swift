import Foundation
@testable import Astrolabe

/// Picks a `FakeResource`'s retry policy and timeout. Policies are statics on the resource
/// type, so each policy under test is its own type.
protocol FakePolicy: Sendable {
    static var name: String { get }
    static var policy: RetryPolicy { get }
    static var timeout: Duration { get }
}

extension FakePolicy {
    static var timeout: Duration { .seconds(60 * 60) }
}

enum Retrying: FakePolicy {
    static let name = "retry"
    static var policy: RetryPolicy { .retry() }
}

enum RollingBack: FakePolicy {
    static let name = "rollback"
    static var policy: RetryPolicy { .rollback() }
}

enum Waiting: FakePolicy {
    static let name = "wait"
    static var policy: RetryPolicy { .wait }
}

/// `.retry()` with a one-minute cap per operation.
enum Capped: FakePolicy {
    static let name = "capped"
    static var policy: RetryPolicy { .retry() }
    static var timeout: Duration { .seconds(60) }
}

/// A resource that acts on the task-local `FakeMachine`. Its id is `fake:<name>`; its hash
/// covers `name` and `value`.
struct FakeResource<P: FakePolicy>: Resource, Equatable {
    static var kind: String { "fake.\(P.name)" }
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    var id: String { "fake:\(name)" }

    static func compute(_ resource: Self) -> String {
        Hash.of(kind, resource.name, resource.value)
    }

    @concurrent static func rollout(_ resource: Self) async throws {
        try await machine().perform(.rollout, id: resource.id, value: resource.value)
    }

    @concurrent static func remove(_ resource: Self) async throws {
        try await machine().perform(.remove, id: resource.id, value: resource.value)
    }

    static var retryPolicy: RetryPolicy { P.policy }
    static var timeout: Duration { P.timeout }

    private static func machine() -> FakeMachine {
        guard let machine = FakeMachine.current else {
            fatalError("FakeResource used outside FakeMachine.$current.withValue")
        }
        return machine
    }
}

typealias RetryFake = FakeResource<Retrying>
typealias RollbackFake = FakeResource<RollingBack>
typealias WaitFake = FakeResource<Waiting>
typealias CappedFake = FakeResource<Capped>
