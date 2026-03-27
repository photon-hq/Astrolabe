import SystemConfiguration

/// A lifecycle trigger that waits for a user to log in,
/// then runs its child steps.
///
/// ```swift
/// UserLogin {
///     Dialog("Welcome") { Button("OK") }
/// }
/// ```
public struct UserLogin<Content: Setup>: Setup {
    public let content: Content

    public init(@SetupBuilder content: () -> Content) {
        self.content = content()
    }

    public func execute() async throws {
        while !hasConsoleUser() {
            try await Task.sleep(for: .seconds(5))
        }
        try await content.execute()
    }

    private func hasConsoleUser() -> Bool {
        var uid: uid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              user != "loginwindow"
        else { return false }
        return true
    }
}
