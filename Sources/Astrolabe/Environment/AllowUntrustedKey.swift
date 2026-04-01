/// Environment key that allows installation of unsigned packages.
struct AllowUntrustedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Whether to allow installation of unsigned packages.
    public var allowUntrusted: Bool {
        get { self[AllowUntrustedKey.self] }
        set { self[AllowUntrustedKey.self] = newValue }
    }
}

extension Setup {
    /// Allows installation of unsigned packages for this declaration and its children.
    public func allowUntrusted() -> ModifiedContent<Self, EnvironmentModifier<Bool>> {
        environment(\.allowUntrusted, true)
    }
}
