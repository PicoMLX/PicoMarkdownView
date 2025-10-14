import Foundation

public struct AssemblerConfig: Sendable, Equatable {
    public var maxClosedBlocks: Int?
    public var maxBytesApprox: Int?
    public var coalescePlainRuns: Bool

    public init(maxClosedBlocks: Int? = 1_000, maxBytesApprox: Int? = nil, coalescePlainRuns: Bool = true) {
        self.maxClosedBlocks = maxClosedBlocks
        self.maxBytesApprox = maxBytesApprox
        self.coalescePlainRuns = coalescePlainRuns
    }
}
