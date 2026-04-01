/// A modifier that presents a dialog during reconciliation.
///
/// Like SwiftUI's `.alert(isPresented:)` — the dialog is shown when
/// `isPresented` is `true`. After the user dismisses it, the binding
/// is set to `false`, triggering re-evaluation.
public struct DialogModifier: SetupModifier, @unchecked Sendable {
    public let title: String
    public let message: String
    public let isPresented: Binding<Bool>
    public let buttons: [Button]

    public init(
        title: String,
        message: String,
        isPresented: Binding<Bool>,
        buttons: [Button]
    ) {
        self.title = title
        self.message = message
        self.isPresented = isPresented
        self.buttons = buttons
    }
}

extension Setup {
    /// Presents a dialog during reconciliation of this declaration.
    public func dialog(
        _ title: String,
        message: String = "",
        isPresented: Binding<Bool>,
        @ButtonBuilder buttons: () -> [Button]
    ) -> ModifiedContent<Self, DialogModifier> {
        ModifiedContent(
            content: self,
            modifier: DialogModifier(
                title: title,
                message: message,
                isPresented: isPresented,
                buttons: buttons()
            )
        )
    }
}
