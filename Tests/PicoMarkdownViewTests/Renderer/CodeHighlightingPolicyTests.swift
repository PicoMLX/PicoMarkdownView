import Testing
@testable import PicoMarkdownView

@Suite
struct CodeHighlightingPolicyTests {
    @Test("Small blocks highlight whether open or closed")
    func smallBlocksAlwaysHighlight() {
        #expect(!CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: 0, isClosed: false))
        #expect(!CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: 512, isClosed: false))
        #expect(!CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: 512, isClosed: true))
        #expect(!CodeHighlightingPolicy.shouldBypassHighlighting(
            byteCount: CodeHighlightingPolicy.streamingByteThreshold, isClosed: false))
    }

    @Test("Streaming blocks past the threshold defer until the fence closes")
    func oversizedStreamingBlocksDefer() {
        let bytes = CodeHighlightingPolicy.streamingByteThreshold + 1
        #expect(CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: bytes, isClosed: false))
        #expect(!CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: bytes, isClosed: true))
    }

    @Test("Blocks past the hard limit never highlight")
    func pathologicalBlocksNeverHighlight() {
        let bytes = CodeHighlightingPolicy.hardByteLimit + 1
        #expect(CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: bytes, isClosed: false))
        #expect(CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: bytes, isClosed: true))
        #expect(!CodeHighlightingPolicy.shouldBypassHighlighting(
            byteCount: CodeHighlightingPolicy.hardByteLimit, isClosed: true))
    }
}
