/// A modifier that alters the behavior or metadata of a `Setup` declaration.
///
/// Modifiers are not tree nodes — they attach metadata to the declaration
/// they modify. The reconciler reads this metadata during reconciliation.
public protocol SetupModifier: Sendable {}
