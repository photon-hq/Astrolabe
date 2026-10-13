/// A piece of a declaration.
///
/// Mirrors SwiftUI's `View`: a component only has a `body`, and the engine walks bodies until it
/// reaches resources. `body` is evaluated on the main actor, inside observation tracking, so any
/// `@Observable` state it reads wakes the engine when it changes.
///
/// ```swift
/// struct DevFiles: Component {
///     let fixture: Fixture
///
///     var body: some Component {
///         for (name, contents) in fixture.files.sorted(by: { $0.key < $1.key }) {
///             StagingFile(path: "/tmp/astrolabe-staging/\(name)", contents: contents)
///         }
///     }
/// }
/// ```
///
/// `body` reads state only: no I/O, and never the records.
@MainActor
public protocol Component {
    associatedtype Body: Component
    @ComponentBuilder var body: Body { get }
}

/// Primitive components have `Body == Never`. The engine destructures them directly.
extension Component where Body == Never {
    public var body: Never { fatalError("\(type(of: self)) has no body") }
}

extension Never: Component {
    public typealias Body = Never
}
