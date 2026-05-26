import Testing
@testable import Astrolabe

private struct DefaultTelemetrySetup: Astrolabe {
    init() {}
    var body: some Setup { EmptySetup() }
}

@Test func defaultTelemetryIsNoop() {
    let t: any AstrolabeTelemetry = DefaultTelemetrySetup.telemetry
    #expect(t is NoopAstrolabeTelemetry)
}

@Test func runAttributesIncludeBackendAndDaemonMode() {
    let attrs = TelemetryAttributes.runAttributes(DefaultTelemetrySetup.self)
    #expect(attrs["telemetry.backend"] == .string("NoopAstrolabeTelemetry"))
    #expect(attrs["astrolabe.daemon_mode"] != nil)
}
