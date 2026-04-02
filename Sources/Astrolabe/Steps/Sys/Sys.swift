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

extension Sys: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        if let hostname = setting as? HostnameSetting {
            return SysInfo(source: .hostname(name: hostname.name))
        } else if let pmset = setting as? PmsetSetting {
            var pairs: [String] = []
            for s in pmset.settings {
                pairs.append(s.key)
                pairs.append(String(s.intValue))
            }
            return SysInfo(source: .pmset(pairs: pairs, source: pmset.source.rawValue))
        } else {
            return SysInfo(source: .custom(typeName: String(describing: type(of: setting))))
        }
    }
}
