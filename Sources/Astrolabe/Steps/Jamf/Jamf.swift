/// A provider that knows how to apply and check a Jamf configuration.
///
/// Conform to this protocol to add custom Jamf settings:
///
/// ```swift
/// struct DisplayNameSetting: JamfSetting {
///     let name: String
///     func check() async throws -> Bool { ... }
///     func apply() async throws { ... }
/// }
/// ```
public protocol JamfSetting: Sendable {
    /// Returns `true` if the setting is already in the desired state.
    func check() async throws -> Bool

    /// Applies the setting. Only called when `check()` returns `false`.
    func apply() async throws
}

/// Declares that a Jamf configuration should be applied.
///
/// `Jamf` is a leaf declaration — mount-only, no unmount. The framework
/// checks if the setting is already applied and skips if so.
/// Jamf must be installed at `/usr/local/bin/jamf` for settings to apply.
///
/// ```swift
/// Jamf(.computerName("dev-mac"))
/// ```
public struct Jamf<Setting: JamfSetting>: Setup {
    public typealias Body = Never

    public let setting: Setting

    public init(_ setting: Setting) {
        self.setting = setting
    }
}

extension Jamf: _ContentIdentifiable {
    var _contentID: String {
        if let computerName = setting as? ComputerNameSetting {
            return "jamf:computerName:\(computerName.name)"
        } else {
            return "jamf:\(String(describing: type(of: setting)))"
        }
    }
}

extension Jamf: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        if let computerName = setting as? ComputerNameSetting {
            return JamfInfo(source: .computerName(name: computerName.name))
        } else {
            return JamfInfo(source: .custom(typeName: String(describing: type(of: setting))))
        }
    }
}
