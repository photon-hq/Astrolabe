/// A leaf node that carries no package — exists purely as a modifier attachment point.
///
/// Use `Anchor` when you need lifecycle modifiers (`.task {}`, `.dialog()`)
/// without an associated package installation.
///
/// ```swift
/// Anchor()
///     .task { await fetchConfig() }
///     .dialog("Welcome!", isPresented: $show) {
///         Button("OK")
///     }
/// ```
public struct Anchor: Setup {
    public typealias Body = Never
    public init() {}
}

extension Anchor: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? { nil }
}
