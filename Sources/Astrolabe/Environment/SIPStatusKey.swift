import Foundation

/// Environment key for System Integrity Protection status.
struct SIPStatusKey: EnvironmentKey {
    /// Seeded `true` — the value the old synchronous probe returned when `csrutil` could not
    /// be run, so a read before the warm-up fails closed exactly as it did before.
    ///
    /// SIP cannot change without a reboot, so `LifecycleEngine` warms this once before the
    /// first tick and never refreshes it.
    static let probe = SystemProbe(initialValue: true) {
        guard let result = try? await ProcessRunner.capture(
            "/usr/bin/csrutil",
            arguments: ["status"]
        ) else { return true }
        return result.standardOutput.contains("enabled")
    }

    static var defaultValue: Bool { probe.current }
}

extension EnvironmentValues {
    /// Whether System Integrity Protection is enabled.
    public var isSIPEnabled: Bool {
        self[SIPStatusKey.self]
    }
}
