import SwiftUI

struct MathBlockView: View {
    var math: RenderedMath

    var body: some View {
        if let artifact = math.artifact {
            Canvas { context, size in
                var mutableContext = context
                MathArtifactRenderer.draw(artifact, in: &mutableContext, size: size)
            }
            .frame(width: artifact.size.width, height: artifact.size.height)
            .accessibilityLabel(Text(math.tex))
        } else {
            Text(verbatim: math.tex)
                .accessibilityLabel(Text(math.tex))
        }
    }
}
