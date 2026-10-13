import Foundation
@testable import Astrolabe

/// A resource that acts on the task-local `FakeMachine`. Its id is `fake:<name>`; its hash
/// covers `name` and `value`. Policies are statics on the resource type, so each policy under
/// test is its own type below.
protocol FakeResource: Resource, Equatable {
    var name: String { get }
    var value: String { get }
    init(name: String, value: String)
}

extension FakeResource {
    init(_ name: String, _ value: String) {
        self.init(name: name, value: value)
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

    private static func machine() -> FakeMachine {
        guard let machine = FakeMachine.current else {
            fatalError("FakeResource used outside FakeMachine.$current.withValue")
        }
        return machine
    }
}

/// `.retry()`, the default.
@Resource
struct RetryFake: FakeResource {
    static let kind = "fake.retry"
    let name: String
    let value: String
}

@Resource
struct RollbackFake: FakeResource {
    static let kind = "fake.rollback"
    let name: String
    let value: String

    static var retryPolicy: RetryPolicy { .rollback() }
}

@Resource
struct WaitFake: FakeResource {
    static let kind = "fake.wait"
    let name: String
    let value: String

    static var retryPolicy: RetryPolicy { .wait }
}

/// `.retry()` with a one-minute cap per operation.
@Resource
struct CappedFake: FakeResource {
    static let kind = "fake.capped"
    let name: String
    let value: String

    static var timeout: Duration { .seconds(60) }
}

/// Every fake, for an engine that should know them all.
let fakeResourceTypes: [any Resource.Type] = [RetryFake.self, RollbackFake.self, WaitFake.self, CappedFake.self]
