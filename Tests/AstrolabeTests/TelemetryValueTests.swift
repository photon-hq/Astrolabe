import Testing
@testable import Astrolabe

@Test func telemetryValueStringCase() {
    let v: TelemetryValue = .string("hello")
    if case .string(let s) = v { #expect(s == "hello") } else { Issue.record("expected .string") }
}

@Test func telemetryValueIntCase() {
    let v: TelemetryValue = .int(42)
    if case .int(let i) = v { #expect(i == 42) } else { Issue.record("expected .int") }
}

@Test func telemetryValueDoubleCase() {
    let v: TelemetryValue = .double(3.14)
    if case .double(let d) = v { #expect(d == 3.14) } else { Issue.record("expected .double") }
}

@Test func telemetryValueBoolCase() {
    let v: TelemetryValue = .bool(true)
    if case .bool(let b) = v { #expect(b == true) } else { Issue.record("expected .bool") }
}

@Test func telemetryValueExpressibleByStringLiteral() {
    let v: TelemetryValue = "literal"
    if case .string(let s) = v { #expect(s == "literal") } else { Issue.record("expected .string") }
}

@Test func telemetryValueExpressibleByIntegerLiteral() {
    let v: TelemetryValue = 7
    if case .int(let i) = v { #expect(i == 7) } else { Issue.record("expected .int") }
}

@Test func telemetryValueExpressibleByFloatLiteral() {
    let v: TelemetryValue = 1.5
    if case .double(let d) = v { #expect(d == 1.5) } else { Issue.record("expected .double") }
}

@Test func telemetryValueExpressibleByBooleanLiteral() {
    let v: TelemetryValue = false
    if case .bool(let b) = v { #expect(b == false) } else { Issue.record("expected .bool") }
}

@Test func telemetryLogLevelHasFourCases() {
    let levels: [TelemetryLogLevel] = [.debug, .info, .warning, .error]
    #expect(levels.count == 4)
}
