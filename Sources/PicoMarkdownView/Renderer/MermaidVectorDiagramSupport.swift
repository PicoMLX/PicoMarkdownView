#if os(macOS)
import Foundation
import CoreGraphics

/// Actor-safe vector output. Parsed drawing objects remain local to the canvas.
struct MermaidVectorRenderResult: Sendable, Equatable {
    var svg: String
    var intrinsicSize: CGSize
    var diagnostics: String? = nil
}

protocol MermaidVectorDiagramProvider: MermaidDiagramProvider {
    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult?
}
#endif
