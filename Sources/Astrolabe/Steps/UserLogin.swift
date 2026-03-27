import SystemConfiguration

/// A lifecycle trigger that waits for a user to log in,
/// then runs its child steps.
///
/// ```swift
/// UserLogin {
///     Dialog("Welcome") { Button("OK") }
/// }
///
/// UserLogin(user: .name("admin")) {
///     // runs only when "admin" logs in
/// }
///
/// UserLogin(user: .uid(501)) {
///     // runs only when UID 501 logs in
/// }
/// ```
public struct UserLogin<Content: Setup>: Setup {
    public enum User: Sendable, Equatable {
        case all
        case name(String)
        case uid(uid_t)
    }

    public let user: User
    public let content: Content

    public init(user: User = .all, @SetupBuilder content: () -> Content) {
        self.user = user
        self.content = content()
    }

    public func execute() async throws {
        while !matchesConsoleUser() {
            try await Task.sleep(for: .seconds(5))
        }
        try await content.execute()
    }

    private func matchesConsoleUser() -> Bool {
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else { return false }

        switch user {
        case .all:
            return true
        case .name(let expected):
            return username == expected
        case .uid(let expected):
            return uid == expected
        }
    }
}
