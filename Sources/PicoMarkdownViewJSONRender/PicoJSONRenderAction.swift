#if os(macOS)
/// A native button action the application can handle, for example by sending
/// a follow-up message in its conversation.
public enum PicoJSONRenderAction: Equatable, Sendable {
    case sendMessage(String)

    public var message: String {
        switch self {
        case .sendMessage(let message): message
        }
    }
}
#endif
