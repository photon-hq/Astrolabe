/// A declarative macOS configuration.
///
/// Conform to this protocol and annotate your struct with `@main`
/// to create a configuration entry point:
///
/// ```swift
/// @main
/// struct MySetup: Astrolabe {
///     var body: some Setup {
///         Wait.userLogin
///         Package.install
///     }
/// }
/// ```
public protocol Astrolabe {
    associatedtype Body: Setup

    @SetupBuilder var body: Body { get }

    init()
}

extension Astrolabe {
    /// Entry point called by the Swift runtime when this type is marked `@main`.
    public static func main() async throws {
        let configuration = Self()
        try await configuration.body.execute()
    }
}
