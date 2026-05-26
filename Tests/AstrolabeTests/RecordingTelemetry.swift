import Foundation
@testable import Astrolabe

/// In-memory recorder that captures every span and log event.
/// Use only in tests; thread-safe via a single NSLock.
final class RecordingTelemetry: AstrolabeTelemetry, @unchecked Sendable {

    enum SpanOutcome: Equatable {
        case ok
        case error(typeName: String)
    }

    struct SpanRecord: Equatable {
        let name: String
        let attributes: [String: TelemetryValue]
        let outcome: SpanOutcome
        /// Monotonic time when the span closed (success or throw), for ordering tests.
        let endedAtUptimeNanoseconds: UInt64
    }

    struct LogRecord: Equatable {
        let level: TelemetryLogLevel
        let message: String
        let attributes: [String: TelemetryValue]
    }

    struct CounterRecord: Equatable {
        let name: String
        let value: Int
        let attributes: [String: TelemetryValue]
    }

    private let lock = NSLock()
    private var _spans: [SpanRecord] = []
    private var _logs: [LogRecord] = []
    private var _counters: [CounterRecord] = []

    var spans: [SpanRecord] { lock.withLock { _spans } }
    var logs: [LogRecord] { lock.withLock { _logs } }
    var counters: [CounterRecord] { lock.withLock { _counters } }

    func span(named name: String) -> SpanRecord? {
        lock.withLock { _spans.first { $0.name == name } }
    }

    func logs(named message: String) -> [LogRecord] {
        lock.withLock { _logs.filter { $0.message == message } }
    }

    func reset() {
        lock.withLock {
            _spans.removeAll()
            _logs.removeAll()
            _counters.removeAll()
        }
    }

    init() {}

    func withSpan<T: Sendable>(
        _ name: String,
        attributes: [String: TelemetryValue],
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            let endedAt = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                _spans.append(SpanRecord(
                    name: name,
                    attributes: attributes,
                    outcome: .ok,
                    endedAtUptimeNanoseconds: endedAt
                ))
            }
            return result
        } catch {
            let endedAt = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                _spans.append(SpanRecord(
                    name: name,
                    attributes: attributes,
                    outcome: .error(typeName: String(describing: type(of: error))),
                    endedAtUptimeNanoseconds: endedAt
                ))
            }
            throw error
        }
    }

    func log(
        _ level: TelemetryLogLevel,
        _ message: String,
        attributes: [String: TelemetryValue]
    ) {
        lock.withLock {
            _logs.append(LogRecord(level: level, message: message, attributes: attributes))
        }
    }

    func recordCounter(
        _ name: String,
        value: Int,
        attributes: [String: TelemetryValue]
    ) {
        lock.withLock {
            _counters.append(CounterRecord(name: name, value: value, attributes: attributes))
        }
    }

    func shutdown() {}
}
