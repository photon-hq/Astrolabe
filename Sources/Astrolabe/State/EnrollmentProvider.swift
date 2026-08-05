import Foundation

/// Checks MDM enrollment status and updates `\.isEnrolled`.
public struct EnrollmentProvider: StateProvider {
    private let lastValue = LockedValue<Bool?>(nil)

    /// Seeded `false` — the same value `EnvironmentValues.isEnrolled` defaults to, and the
    /// same value the old synchronous probe returned when `profiles` could not be run. The
    /// first poll converges it to the truth.
    private let probe = SystemProbe(initialValue: false) {
        guard let result = try? await ProcessRunner.capture(
            "/usr/bin/profiles",
            arguments: ["status", "-type", "enrollment"]
        ) else { return false }

        // Parsed from stdout only, matching the old behavior — `profiles` writes unrelated
        // noise to stderr.
        return result.standardOutput.contains("Yes (User Approved)")
            || result.standardOutput.contains("MDM enrollment: Yes")
    }

    public init() {}

    public func check(updating environment: inout EnvironmentValues) -> Bool {
        // `check` runs inside `StateNotifier`'s lock, so it reads the cache and lets the
        // refresh happen off to the side. See `SystemProbe`.
        probe.refreshInBackground()
        let current = probe.current
        environment.isEnrolled = current
        return lastValue.exchange(current)
    }

    /// Reads enrollment once and waits, so the first tick sees a real value.
    func warmUp() async {
        await probe.refresh()
    }
}
