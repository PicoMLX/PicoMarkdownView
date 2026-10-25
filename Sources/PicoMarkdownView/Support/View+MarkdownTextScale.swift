import SwiftUI

public extension View {
    /// Scales the Markdown fonts (body, code, headings, math) of every
    /// `PicoMarkdownView` below this view by `scale`, live: the parse and any
    /// running stream are kept, only the presentation is rebuilt. Multiplies
    /// with the system's Dynamic Type setting, which the view follows on its
    /// own. Use it for zoom controls.
    func markdownTextScale(_ scale: CGFloat) -> some View {
        environment(\.picoTextScale, scale)
    }
}

private struct PicoTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var picoTextScale: CGFloat {
        get { self[PicoTextScaleKey.self] }
        set { self[PicoTextScaleKey.self] = newValue }
    }
}
