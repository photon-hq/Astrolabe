/// A modifier that presents a list picker during reconciliation.
///
/// Like SwiftUI's selection-based APIs, the binding type determines behavior:
/// - `Binding<String?>` — single selection
/// - `Binding<Set<String>>` — multiple selection
public struct ListDialogModifier: SetupModifier, @unchecked Sendable {
    public let prompt: String
    public let items: [String]
    public let defaultItems: [String]
    public let multipleSelection: Bool
    public let isPresented: Binding<Bool>
    public let onSelection: @Sendable ([String]) -> Void
}

extension Setup {
    /// Presents a single-selection list dialog during reconciliation.
    public func listDialog(
        _ prompt: String,
        items: [String],
        selection: Binding<String?>,
        isPresented: Binding<Bool>
    ) -> ModifiedContent<Self, ListDialogModifier> {
        let currentValue = selection.wrappedValue
        return ModifiedContent(
            content: self,
            modifier: ListDialogModifier(
                prompt: prompt,
                items: items,
                defaultItems: currentValue.map { [$0] } ?? [],
                multipleSelection: false,
                isPresented: isPresented,
                onSelection: { selection.wrappedValue = $0.first }
            )
        )
    }

    /// Presents a multiple-selection list dialog during reconciliation.
    public func listDialog(
        _ prompt: String,
        items: [String],
        selection: Binding<Set<String>>,
        isPresented: Binding<Bool>
    ) -> ModifiedContent<Self, ListDialogModifier> {
        let currentValue = selection.wrappedValue
        return ModifiedContent(
            content: self,
            modifier: ListDialogModifier(
                prompt: prompt,
                items: items,
                defaultItems: Array(currentValue),
                multipleSelection: true,
                isPresented: isPresented,
                onSelection: { selection.wrappedValue = Set($0) }
            )
        )
    }
}
