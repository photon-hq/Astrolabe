import Testing
@testable import Astrolabe

private struct DefaultTelemetryApp: Astrolabe {
    var body: some Component { EmptyComponent() }
}

@MainActor
@Test func defaultTelemetryIsNoop() {
    let t: any AstrolabeTelemetry = DefaultTelemetryApp.telemetry
    #expect(t is NoopAstrolabeTelemetry)
}

@MainActor
@Test func runAttributesIncludeBackendAndMode() {
    let attrs = TelemetryAttributes.runAttributes(DefaultTelemetryApp.self, mode: .dryRun, records: 3)
    #expect(attrs["telemetry.backend"] == .string("NoopAstrolabeTelemetry"))
    #expect(attrs["astrolabe.engine.mode"] == .string("dry_run"))
    #expect(attrs["astrolabe.records.count"] == .int(3))
}
