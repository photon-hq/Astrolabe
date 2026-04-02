/// The role of a button in a dialog, influencing its placement and styling.
///
/// Mirrors SwiftUI's `ButtonRole`. Buttons without a role are treated as
/// primary/default actions.
public enum ButtonRole: Sendable, Equatable {
    /// A button that cancels the dialog. Gets Escape key equivalent.
    case cancel
    /// A destructive action. Styled with a warning appearance.
    case destructive
}
