/// A declarative configuration declaration.
///
/// The fundamental building block of Astrolabe. Mirrors SwiftUI's `View` — requires
/// only `body`. The framework walks the tree recursively until it hits leaf nodes
/// (`Body == Never`).
///
/// ```swift
/// struct DevTools: Setup {
///     var body: some Setup {
///         Pkg("wget")
///         Pkg("git-lfs")
///     }
/// }
/// ```
public protocol Setup: Sendable {
    associatedtype Body: Setup
    @SetupBuilder var body: Body { get }
}

/// Leaf nodes have `Body == Never`. The framework stops walking and reconciles directly.
extension Setup where Body == Never {
    public var body: Never { fatalError("Leaf node \(type(of: self)) has no body") }
}

extension Never: Setup {
    public typealias Body = Never
}
