import Testing
@testable import Astrolabe

private struct NoopTestError: Error, Equatable {}

@Test func noopWithSpanReturnsOperationResult() async throws {
    let noop = NoopAstrolabeTelemetry()
    let result = try await noop.withSpan("op", attributes: [:]) { 42 }
    #expect(result == 42)
}

@Test func noopWithSpanRethrowsErrors() async {
    let noop = NoopAstrolabeTelemetry()
    do {
        _ = try await noop.withSpan("op", attributes: [:]) { () async throws -> Int in
            throw NoopTestError()
        }
        Issue.record("expected throw")
    } catch is NoopTestError {
        // expected
    } catch {
        Issue.record("expected NoopTestError, got \(type(of: error))")
    }
}

@Test func noopLogDoesNotThrow() {
    let noop = NoopAstrolabeTelemetry()
    noop.log(.info, "hello", attributes: ["k": "v"])
    noop.log(.error, "oops", attributes: [:])
}

@Test func noopRecordCounterDoesNotThrow() {
    let noop = NoopAstrolabeTelemetry()
    noop.recordCounter("c", value: 1, attributes: [:])
    noop.recordCounter("c", value: 100, attributes: ["k": .int(7)])
}

@Test func noopWithSpanConvenienceOverloadCompiles() async throws {
    let noop = NoopAstrolabeTelemetry()
    let result = try await noop.withSpan("op") { "ok" }
    #expect(result == "ok")
}

@Test func noopShutdownDoesNotThrow() {
    NoopAstrolabeTelemetry().shutdown()
}

@Test func noopVerboseNodeAttributesIsFalse() {
    #expect(NoopAstrolabeTelemetry().verboseNodeAttributes == false)
}
