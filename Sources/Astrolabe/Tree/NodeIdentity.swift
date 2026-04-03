/// A component in a node's identity path within the declaration tree.
///
/// Each component represents a structural decision point — an index within
/// a sequence, a branch in a conditional, or the presence of an optional.
/// Leaf nodes with inherent identity use `.named` instead of positional index.
public enum PathComponent: Hashable, Codable, Sendable {
    /// Position within a `SetupSequence`.
    case index(Int)
    /// Branch of a `ConditionalSetup`.
    case conditional(Branch)
    /// Content of an `OptionalSetup`.
    case optional
    /// Content-based identity for nodes with inherent identity (e.g. package name, daemon label).
    case named(String)

    public enum Branch: Hashable, Codable, Sendable {
        case first
        case second
    }
}

/// The structural identity of a node in the declaration tree.
///
/// Derived from the node's position in the type hierarchy — its path through
/// sequences, conditionals, and optionals. Analogous to how SwiftUI uses
/// type + position to identify views.
public struct NodeIdentity: Hashable, Codable, Sendable {
    public let path: [PathComponent]

    public init(_ path: [PathComponent] = []) {
        self.path = path
    }

    public func appending(_ component: PathComponent) -> NodeIdentity {
        NodeIdentity(path + [component])
    }
}
