import SystemConfiguration

/// Checks the current console user and updates `\.consoleUser`.
public struct ConsoleUserProvider: StateProvider {
    private let lastValue = LockedValue<String?>(nil)

    public init() {}

    public func check(updating environment: inout EnvironmentValues) -> Bool {
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else {
            environment.consoleUser = nil
            return lastValue.exchange(nil as String?)
        }
        environment.consoleUser = ConsoleUser(name: username, uid: uid)
        return lastValue.exchange(username)
    }
}
