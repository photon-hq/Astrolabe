import Testing
@testable import Astrolabe

struct TrackingStep: Setup {
    let id: String
    let log: Log

    func execute() async throws {
        log.append(id)
    }
}

final class Log: @unchecked Sendable {
    private var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }

    var values: [String] { entries }
}

@Test func emptySetupDoesNothing() async throws {
    let empty = EmptySetup()
    try await empty.execute()
}

@Test func singleStepExecutes() async throws {
    let log = Log()
    let step = TrackingStep(id: "a", log: log)
    try await step.execute()
    #expect(log.values == ["a"])
}

@Test func resultBuilderSequentialOrder() async throws {
    let log = Log()

    @SetupBuilder var setup: some Setup {
        TrackingStep(id: "1", log: log)
        TrackingStep(id: "2", log: log)
        TrackingStep(id: "3", log: log)
    }

    try await setup.execute()
    #expect(log.values == ["1", "2", "3"])
}

@Test func resultBuilderConditional() async throws {
    let log = Log()
    let flag = true

    @SetupBuilder var setup: some Setup {
        if flag {
            TrackingStep(id: "true", log: log)
        } else {
            TrackingStep(id: "false", log: log)
        }
    }

    try await setup.execute()
    #expect(log.values == ["true"])
}

@Test func resultBuilderOptional() async throws {
    let log = Log()
    let include = false

    @SetupBuilder var setup: some Setup {
        if include {
            TrackingStep(id: "skipped", log: log)
        }
    }

    try await setup.execute()
    #expect(log.values == [])
}

@Test func astrolabeProtocolMain() async throws {
    struct TestConfig: Astrolabe {
        static let sharedLog = Log()

        var body: some Setup {
            TrackingStep(id: "a", log: Self.sharedLog)
            TrackingStep(id: "b", log: Self.sharedLog)
        }
    }

    try await TestConfig.main()
    #expect(TestConfig.sharedLog.values == ["a", "b"])
}

@Test func waitStepExists() async throws {
    let wait: any Setup = Wait.userLogin
    try await wait.execute()
}

@Test func packageGitHub() async throws {
    let pkg = PackageInstaller(.gitHub("owner/repo"))
    #expect(pkg.provider.repo == "owner/repo")
    #expect(pkg.provider.version == .latest)
}

@Test func packageGitHubWithTag() async throws {
    let pkg = PackageInstaller(.gitHub("owner/repo", version: .tag("v1.0.0")))
    #expect(pkg.provider.repo == "owner/repo")
    if case .tag(let tag) = pkg.provider.version {
        #expect(tag == "v1.0.0")
    } else {
        #expect(Bool(false), "Expected .tag version")
    }
}

@Test func packageJamfName() async throws {
    let pkg = PackageInstaller(.jamf(name: "Google Chrome"))
    if case .name(let name) = pkg.provider.identifier {
        #expect(name == "Google Chrome")
    } else {
        #expect(Bool(false), "Expected .name identifier")
    }
}

@Test func packageJamfId() async throws {
    let pkg = PackageInstaller(.jamf(id: 1265))
    if case .id(let id) = pkg.provider.identifier {
        #expect(id == 1265)
    } else {
        #expect(Bool(false), "Expected .id identifier")
    }
}

@Test func packageJamfTrigger() async throws {
    let pkg = PackageInstaller(.jamf(trigger: "installChrome"))
    if case .trigger(let trigger) = pkg.provider.identifier {
        #expect(trigger == "installChrome")
    } else {
        #expect(Bool(false), "Expected .trigger identifier")
    }
}

@Test func packageCustomProvider() async throws {
    struct TestProvider: PackageProvider {
        let log: Log
        func install() async throws {
            log.append("installed")
        }
    }

    let log = Log()
    let pkg = PackageInstaller(TestProvider(log: log))
    try await pkg.execute()
    #expect(log.values == ["installed"])
}

@Test func packageInSetupBuilder() async throws {
    @SetupBuilder var setup: some Setup {
        PackageInstaller(.gitHub("owner/repo"))
        PackageInstaller(.jamf(name: "Slack"))
    }
    // Verify it compiles as Setup steps
    _ = setup
}

@Test func dialogConstruction() async throws {
    let dialog = Dialog("Title", message: "Hello") {
        Button("OK")
        Button("Cancel")
    }

    #expect(dialog.title == "Title")
    #expect(dialog.message == "Hello")
    #expect(dialog.buttons.count == 2)
    #expect(dialog.buttons[0].label == "OK")
    #expect(dialog.buttons[1].label == "Cancel")
}

@Test func dialogManyButtons() async throws {
    let dialog = Dialog("Pick") {
        Button("A")
        Button("B")
        Button("C")
        Button("D")
        Button("E")
    }

    #expect(dialog.buttons.count == 5)
    #expect(dialog.buttons.map(\.label) == ["A", "B", "C", "D", "E"])
}

@Test func dialogConditionalButtons() async throws {
    let isAdmin = true

    let dialog = Dialog("Setup") {
        Button("Continue")
        if isAdmin {
            Button("Advanced")
        }
    }

    #expect(dialog.buttons.count == 2)
    #expect(dialog.buttons[1].label == "Advanced")
}

@Test func dialogDefaultMessage() async throws {
    let dialog = Dialog("Title") {
        Button("OK")
    }

    #expect(dialog.message == "")
}

@Test func dialogInSetupBuilder() async throws {
    // Verify Dialog compiles inside a @SetupBuilder body
    struct TestConfig: Astrolabe {
        var body: some Setup {
            Dialog("Welcome") {
                Button("OK")
            }
        }
    }

    let config = TestConfig()
    // Just verify it builds — execution would show a real dialog
    _ = config.body
}

@Test func buttonWithAction() async throws {
    let log = Log()

    let button = Button("OK") {
        log.append("pressed")
    }

    #expect(button.label == "OK")
    try await button.action()
    #expect(log.values == ["pressed"])
}

@Test func buttonWithoutAction() async throws {
    let button = Button("OK")
    // Default action is a no-op — should not throw
    try await button.action()
}

@Test func dialogButtonActions() async throws {
    let log = Log()

    let dialog = Dialog("Test") {
        Button("A") { log.append("a") }
        Button("B") { log.append("b") }
    }

    // Verify actions are stored correctly
    try await dialog.buttons[0].action()
    try await dialog.buttons[1].action()
    #expect(log.values == ["a", "b"])
}
