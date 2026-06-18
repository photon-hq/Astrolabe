import SignozSwift
import Testing
@testable import Astrolabe

@Test func signozAdapterInitShutdownAndConformance() async {
    let adapter = SignozAstrolabeTelemetry(serviceName: "astrolabe-test") { config in
        config.endpoint = "127.0.0.1:0"
    }
    let _: any AstrolabeTelemetry = adapter
    adapter.shutdown()
}

@Test func telemetryValueMapsToAttributeValueString() {
    let av = SignozAstrolabeTelemetry.toAttributeValue(.string("x"))
    if case .string(let s) = av { #expect(s == "x") } else { Issue.record("expected .string") }
}

@Test func telemetryValueMapsToAttributeValueInt() {
    let av = SignozAstrolabeTelemetry.toAttributeValue(.int(42))
    if case .int(let i) = av { #expect(i == 42) } else { Issue.record("expected .int") }
}

@Test func telemetryValueMapsToAttributeValueDouble() {
    let av = SignozAstrolabeTelemetry.toAttributeValue(.double(2.5))
    if case .double(let d) = av { #expect(d == 2.5) } else { Issue.record("expected .double") }
}

@Test func telemetryValueMapsToAttributeValueBool() {
    let av = SignozAstrolabeTelemetry.toAttributeValue(.bool(true))
    if case .bool(let b) = av { #expect(b == true) } else { Issue.record("expected .bool") }
}
