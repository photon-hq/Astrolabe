/// A provider that knows how to apply and check a system configuration.
///
/// Conform to this protocol to add custom system settings:
///
/// ```swift
/// struct TimezoneSetting: SystemSetting {
///     let zone: String
///     func check() async throws -> Bool { ... }
///     func apply() async throws { ... }
/// }
/// ```
public protocol SystemSetting: Sendable {
    /// Returns `true` if the setting is already in the desired state.
    func check() async throws -> Bool

    /// Applies the setting. Only called when `check()` returns `false`.
    func apply() async throws
}

/// Declares that a system configuration should be applied.
///
/// `Sys` is a leaf declaration — mount-only, no unmount. The framework
/// checks if the setting is already applied and skips if so.
///
/// ```swift
/// Sys(.hostname("dev-mac"))
/// ```
public struct Sys<Setting: SystemSetting>: Setup {
    public typealias Body = Never

    public let setting: Setting

    public init(_ setting: Setting) {
        self.setting = setting
    }
}
