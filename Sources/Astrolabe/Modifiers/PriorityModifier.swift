/// A modifier that controls install/uninstall ordering.
///
/// Lower values install first and uninstall last.
public struct PriorityModifier: SetupModifier {
    public let value: Int

    public init(value: Int) {
        self.value = value
    }
}

extension Setup {
    /// Sets the install priority. Lower values install first and uninstall last.
    public func priority(_ value: Int) -> ModifiedContent<Self, PriorityModifier> {
        ModifiedContent(content: self, modifier: PriorityModifier(value: value))
    }
}
