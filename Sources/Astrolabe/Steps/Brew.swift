/// Declares that a Homebrew package should be installed.
///
/// `Brew` is a leaf declaration — it has no body. The framework reconciles it
/// by running `brew install`.
///
/// ```swift
/// Brew("wget")
/// Brew("firefox", type: .cask)
/// ```
public struct Brew: Setup {
    public typealias Body = Never

    public enum PackageType: Sendable, Equatable {
        case formula
        case cask
    }

    public let name: String
    public let type: PackageType

    public init(_ name: String, type: PackageType = .formula) {
        self.name = name
        self.type = type
    }
}

extension Brew: Installable {}

extension Brew: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        let brewType: BrewInfo.BrewType = switch type {
        case .formula: .formula
        case .cask: .cask
        }
        return BrewInfo(name: name, type: brewType)
    }
}
