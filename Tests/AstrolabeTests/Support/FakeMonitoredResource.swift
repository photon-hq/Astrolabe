import Foundation
@testable import Astrolabe

/// How the fake Mac says a monitored fake looks. Read every 10 seconds, so a drift is seen.
struct HealthKey: FakeFactKey {
    static let defaultValue = ""
    static let schedule: FactSchedule = .every(.seconds(10))
}

extension Facts {
    var health: String { self[HealthKey.self] }
}

/// A `FakeResource` that monitors `\.health`. Its rollout puts `value@health` on the Mac, `-` for
/// an unread monitor, so each call shows what the snapshot was built with.
protocol MonitoredFakeResource: FakeResource {
    var health: String? { get }
    /// A snapshot as a pass that read `health` would build it.
    init(name: String, value: String, health: String?)
}

extension MonitoredFakeResource {
    @concurrent static func rollout(_ resource: Self) async throws {
        try await machine().perform(.rollout, id: resource.id, value: "\(resource.value)@\(resource.health ?? "-")")
    }
}

/// `.retry()`, monitoring `\.health`.
@Resource
struct MonitoredFake: MonitoredFakeResource {
    static let kind = "fake.monitored"
    let name: String
    let value: String
    @Monitor(\.health) var health

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    init(name: String, value: String, health: String?) {
        self.init(name: name, value: value)
        _health = Monitor(observed: health)
    }
}

/// `.rollback()`, monitoring `\.health`.
@Resource
struct MonitoredRollbackFake: MonitoredFakeResource {
    static let kind = "fake.monitored.rollback"
    let name: String
    let value: String
    @Monitor(\.health) var health

    static var retryPolicy: RetryPolicy { .rollback() }

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    init(name: String, value: String, health: String?) {
        self.init(name: name, value: value)
        _health = Monitor(observed: health)
    }
}

/// Declares one `R`, `m`, valued `test.tracked`. Built in `body`, so it reads `\.health`.
struct MonitoredApp<R: MonitoredFakeResource>: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        R(name: "m", value: "\(test.tracked)")
    }
}

extension TestState {
    /// `HealthKey`, written through to the fake Mac and injected.
    var health: String {
        get { fakeFacts.value(HealthKey.self) ?? HealthKey.defaultValue }
        nonmutating set {
            fakeFacts.set(HealthKey.self, newValue)
            facts.inject(\.health, newValue)
        }
    }
}
