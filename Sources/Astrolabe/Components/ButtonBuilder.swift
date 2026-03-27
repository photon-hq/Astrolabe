/// A result builder that collects buttons for use in dialogs.
@resultBuilder
public struct ButtonBuilder {
    public static func buildExpression(_ button: Button) -> [Button] {
        [button]
    }

    public static func buildBlock(_ components: [Button]...) -> [Button] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [Button]?) -> [Button] {
        component ?? []
    }

    public static func buildEither(first component: [Button]) -> [Button] {
        component
    }

    public static func buildEither(second component: [Button]) -> [Button] {
        component
    }
}
