/// Environment key for MDM enrollment status.
struct IsEnrolledKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Whether the device is MDM-enrolled.
    public var isEnrolled: Bool {
        get { self[IsEnrolledKey.self] }
        set { self[IsEnrolledKey.self] = newValue }
    }
}
