#if os(macOS)
import SwiftUI

public extension View {
    /// Receives actions from completed, opted-in OpenUI fences. The original
    /// action type, context and form values are passed through; the app owns
    /// any model request, navigation or tool execution.
    func onOpenUIAction(_ handler: @escaping (PicoOpenUIActionEvent) -> Void) -> some View {
        environment(\.picoOnOpenUIAction, handler)
    }
}

private struct PicoOnOpenUIActionKey: EnvironmentKey {
    static var defaultValue: ((PicoOpenUIActionEvent) -> Void)? { nil }
}

extension EnvironmentValues {
    var picoOnOpenUIAction: ((PicoOpenUIActionEvent) -> Void)? {
        get { self[PicoOnOpenUIActionKey.self] }
        set { self[PicoOnOpenUIActionKey.self] = newValue }
    }
}
#endif
