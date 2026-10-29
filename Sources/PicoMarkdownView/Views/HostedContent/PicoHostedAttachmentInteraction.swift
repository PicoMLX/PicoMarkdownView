#if os(macOS)
/// How pointer input in a hosted attachment interacts with document selection.
public enum PicoHostedAttachmentInteraction: Sendable {
    /// Select the block with the surrounding text. Explicit link targets may
    /// still handle clicks; other pointer input belongs to the parent text view.
    case selectableBlock
    /// Let the hosted controls handle pointer input normally.
    case interactive
}
#endif
