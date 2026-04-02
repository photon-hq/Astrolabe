// MARK: - Environment Keys

struct LaunchdKeepAliveKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

struct LaunchdRunAtLoadKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

struct LaunchdStartIntervalKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

struct LaunchdStandardOutPathKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

struct LaunchdStandardErrorPathKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

struct LaunchdWorkingDirectoryKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

struct LaunchdEnvironmentVariablesKey: EnvironmentKey {
    static let defaultValue: [String: String]? = nil
}

struct LaunchdThrottleIntervalKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

struct LaunchdActivateKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

// MARK: - EnvironmentValues

extension EnvironmentValues {
    public var launchdKeepAlive: Bool? {
        get { self[LaunchdKeepAliveKey.self] }
        set { self[LaunchdKeepAliveKey.self] = newValue }
    }

    public var launchdRunAtLoad: Bool? {
        get { self[LaunchdRunAtLoadKey.self] }
        set { self[LaunchdRunAtLoadKey.self] = newValue }
    }

    public var launchdStartInterval: Int? {
        get { self[LaunchdStartIntervalKey.self] }
        set { self[LaunchdStartIntervalKey.self] = newValue }
    }

    public var launchdStandardOutPath: String? {
        get { self[LaunchdStandardOutPathKey.self] }
        set { self[LaunchdStandardOutPathKey.self] = newValue }
    }

    public var launchdStandardErrorPath: String? {
        get { self[LaunchdStandardErrorPathKey.self] }
        set { self[LaunchdStandardErrorPathKey.self] = newValue }
    }

    public var launchdWorkingDirectory: String? {
        get { self[LaunchdWorkingDirectoryKey.self] }
        set { self[LaunchdWorkingDirectoryKey.self] = newValue }
    }

    public var launchdEnvironmentVariables: [String: String]? {
        get { self[LaunchdEnvironmentVariablesKey.self] }
        set { self[LaunchdEnvironmentVariablesKey.self] = newValue }
    }

    public var launchdThrottleInterval: Int? {
        get { self[LaunchdThrottleIntervalKey.self] }
        set { self[LaunchdThrottleIntervalKey.self] = newValue }
    }

    public var launchdActivate: Bool {
        get { self[LaunchdActivateKey.self] }
        set { self[LaunchdActivateKey.self] = newValue }
    }
}

// MARK: - Modifier Sugar

extension Setup {
    /// Keeps the launchd job alive (restarts on exit).
    public func keepAlive() -> ModifiedContent<Self, EnvironmentModifier<Bool?>> {
        environment(\.launchdKeepAlive, true)
    }

    /// Starts the launchd job when it is loaded.
    public func runAtLoad() -> ModifiedContent<Self, EnvironmentModifier<Bool?>> {
        environment(\.launchdRunAtLoad, true)
    }

    /// Runs the launchd job every `seconds` seconds.
    public func startInterval(_ seconds: Int) -> ModifiedContent<Self, EnvironmentModifier<Int?>> {
        environment(\.launchdStartInterval, seconds)
    }

    /// Sets the standard output log path for the launchd job.
    public func standardOutPath(_ path: String) -> ModifiedContent<Self, EnvironmentModifier<String?>> {
        environment(\.launchdStandardOutPath, path)
    }

    /// Sets the standard error log path for the launchd job.
    public func standardErrorPath(_ path: String) -> ModifiedContent<Self, EnvironmentModifier<String?>> {
        environment(\.launchdStandardErrorPath, path)
    }

    /// Sets the working directory for the launchd job.
    public func workingDirectory(_ path: String) -> ModifiedContent<Self, EnvironmentModifier<String?>> {
        environment(\.launchdWorkingDirectory, path)
    }

    /// Sets environment variables for the launchd job.
    public func environmentVariables(_ vars: [String: String]) -> ModifiedContent<Self, EnvironmentModifier<[String: String]?>> {
        environment(\.launchdEnvironmentVariables, vars)
    }

    /// Sets the minimum interval between job invocations.
    public func throttleInterval(_ seconds: Int) -> ModifiedContent<Self, EnvironmentModifier<Int?>> {
        environment(\.launchdThrottleInterval, seconds)
    }

    /// Immediately bootstraps the launchd job after writing the plist.
    /// For LaunchDaemons: bootout → enable → bootstrap into system domain.
    /// For LaunchAgents: bootout → enable → bootstrap into every logged-in user's GUI session.
    public func activate() -> ModifiedContent<Self, EnvironmentModifier<Bool>> {
        environment(\.launchdActivate, true)
    }
}
