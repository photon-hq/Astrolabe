import Darwin

/// A logged-in console user.
public struct ConsoleUser: Sendable, Equatable {
    public let name: String
    public let uid: uid_t

    public init(name: String, uid: uid_t) {
        self.name = name
        self.uid = uid
    }
}

/// Environment key for the current console user.
struct ConsoleUserKey: EnvironmentKey {
    static let defaultValue: ConsoleUser? = nil
}

extension EnvironmentValues {
    /// The currently logged-in console user, or `nil` if no user is logged in.
    public var consoleUser: ConsoleUser? {
        get { self[ConsoleUserKey.self] }
        set { self[ConsoleUserKey.self] = newValue }
    }
}
