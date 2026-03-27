/// A declarative macOS configuration.
///
/// Conform to this protocol and annotate your struct with `@main`
/// to create a configuration entry point:
///
/// ```swift
/// @main
/// struct MySetup: Astrolabe {
///     var body: some Setup {
///         EnrollmentComplete {
///             DevTools()
///         }
///         UserLogin {
///             PackageInstaller(.gitHub("owner/repo"))
///         }
///     }
/// }
/// ```
public protocol Astrolabe: Setup {
    associatedtype Body: Setup

    @SetupBuilder var body: Body { get }

    init()
}

extension Astrolabe {
    /// Executes this configuration's body. Enables nesting one Astrolabe inside another.
    public func execute() async throws {
        try await body.execute()
    }

    /// Entry point called by the Swift runtime when this type is marked `@main`.
    public static func main() async throws {
        let configuration = Self()
        try await configuration.execute()
    }
}
