/// Declares that a Homebrew package should be installed.
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

extension Brew: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let flag = type == .cask ? "cask" : "formula"
        let identity = NodeIdentity([.named("brew:\(flag):\(name)")])
        return TreeNode(identity: identity, kind: .leaf(BrewInfo(name: name, type: type)))
    }
}
