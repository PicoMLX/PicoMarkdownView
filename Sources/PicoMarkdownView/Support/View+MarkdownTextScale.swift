import SwiftUI

public extension View {
    /// Scales Markdown fonts and math live, in addition to Dynamic Type.
    /// The tokenizer and active stream are preserved when this value changes.
    func markdownTextScale(_ scale: CGFloat) -> some View {
        environment(\.picoTextScale, scale)
    }
}

private struct PicoTextScaleKey: EnvironmentKey {
    static var defaultValue: CGFloat { 1 }
}

extension EnvironmentValues {
    var picoTextScale: CGFloat {
        get { self[PicoTextScaleKey.self] }
        set { self[PicoTextScaleKey.self] = newValue }
    }
}
