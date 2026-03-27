/// A declarative configuration step that can be executed.
///
/// Analogous to SwiftUI's `View` or `Scene` protocol.
/// Every configuration action conforms to `Setup`.
public protocol Setup: Sendable {
    /// Executes this configuration step.
    func execute() async throws
}
