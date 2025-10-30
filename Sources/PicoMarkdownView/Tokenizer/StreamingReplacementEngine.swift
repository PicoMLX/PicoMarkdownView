import Foundation

struct StreamingReplacementEngine {
    private struct LiteralPattern {
        let string: String
        let characters: [Character]
        let replacement: String
        let requiresLookahead: Bool
    }

    private enum ColonState {
        case idle
        case pending
        case collecting
    }

    private static let defaultLiteralReplacements: [(String, String)] = [
//        ("---", "—"),
//        ("--", "–"),
        ("...", "…"),
        ("(tm)", "™"),
        ("(TM)", "™"),
        ("(r)", "®"),
        ("(R)", "®"),
        ("(c)", "©"),
        ("(C)", "©"),
        ("(p)", "§"),
        ("(P)", "§"),
        (":-)", "🙂"),
        (":)", "🙂"),
        ("8-)", "😎"),
        (";-)", "😉"),
        (";)", "😉"),
        (":-D", "😃"),
        (":-(", "🙁"),
        (":-P", "😛"),
    ]

    private static let defaultEmojiShortcodes: [String: String] = [
        "smile": "😄",
        "heart": "❤️",
        "laughing": "😆",
        "wink": "😉",
        "yum": "😋",
        "cry": "😢",
    ]

    private static func buildLiteralPatterns(from raw: [(String, String)]) -> [LiteralPattern] {
        let lookahead = Set(raw.compactMap { candidate -> String? in
            raw.contains(where: { other in other.0.count > candidate.0.count && other.0.hasPrefix(candidate.0) }) ? candidate.0 : nil
        })
        return raw
            .sorted { lhs, rhs in lhs.0.count > rhs.0.count }
            .map { LiteralPattern(string: $0.0,
                                  characters: Array($0.0),
                                  replacement: $0.1,
                                  requiresLookahead: lookahead.contains($0.0)) }
    }

    private let literalPatterns: [LiteralPattern]
    private let literalPrefixSet: Set<String>
    private let maxLiteralPatternLength: Int
    private let emojiShortcodes: [String: String]
    private var literalTail: [Character] = []
    private var colonState: ColonState = .idle
    private var colonBuffer: [Character] = []
    private var colonContent: String = ""
    private let maxShortcodeLength = 64

    init(literalReplacements: [(String, String)]? = nil,
         emojiShortcodes: [String: String]? = nil) {
        let configuredReplacements = literalReplacements ?? Self.defaultLiteralReplacements
        self.literalPatterns = Self.buildLiteralPatterns(from: configuredReplacements)
        self.literalPrefixSet = Set(self.literalPatterns.flatMap { pattern -> [String] in
            guard pattern.characters.count > 1 else { return [] }
            return (1..<pattern.characters.count).map { String(pattern.characters.prefix($0)) }
        })
        self.maxLiteralPatternLength = self.literalPatterns.map { $0.characters.count }.max() ?? 0
        self.emojiShortcodes = (emojiShortcodes ?? Self.defaultEmojiShortcodes)
    }

    mutating func process(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var output = String()
        output.reserveCapacity(text.count)
        for character in text {
            handle(character, into: &output)
        }
        return output
    }

    mutating func finish() -> String {
        var output = String()
        if colonState != .idle {
            flushColonBuffer(into: &output)
            colonState = .idle
        }
        while let replacement = matchLiteralPattern(allowLookahead: true) {
            output.append(replacement)
        }
        if !literalTail.isEmpty {
            output.append(String(literalTail))
            literalTail.removeAll(keepingCapacity: true)
        }
        return output
    }

    mutating func reset() {
        literalTail.removeAll(keepingCapacity: true)
        colonBuffer.removeAll(keepingCapacity: true)
        colonContent.removeAll(keepingCapacity: true)
        colonState = .idle
    }

    mutating func flushTrailingPeriods(into output: inout String) {
        guard !literalTail.isEmpty else { return }
        var flushed: [Character] = []
        while let last = literalTail.last, last == "." {
            flushed.append(last)
            literalTail.removeLast()
        }
        guard !flushed.isEmpty else { return }
        output.append(contentsOf: flushed.reversed())
    }

    private mutating func handle(_ character: Character, into output: inout String) {
        let current = character
        var shouldReprocess = true
        while shouldReprocess {
            shouldReprocess = false
            switch colonState {
            case .idle:
                if current == ":" {
                    colonState = .pending
                    colonBuffer = [":"]
                    colonContent = ""
                    continue
                }
                appendLiteral(current, into: &output)
            case .pending:
                if isShortcodeInitial(current) {
                    colonState = .collecting
                    colonBuffer.append(current)
                    colonContent = String(current)
                } else {
                    flushColonBuffer(into: &output)
                    colonState = .idle
                    shouldReprocess = true
                }
            case .collecting:
                if current == ":" {
                    if let emoji = emojiShortcodes[colonContent.lowercased()], !colonContent.isEmpty {
                        colonState = .idle
                        colonBuffer.removeAll(keepingCapacity: true)
                        colonContent.removeAll(keepingCapacity: true)
                        output.append(emoji)
                    } else {
                        colonBuffer.append(":")
                        flushColonBuffer(into: &output)
                        colonState = .idle
                    }
                } else if isShortcodeContinuation(current) && colonContent.count < maxShortcodeLength {
                    colonBuffer.append(current)
                    colonContent.append(current)
                } else {
                    flushColonBuffer(into: &output)
                    colonState = .idle
                    shouldReprocess = true
                }
            }
        }
    }

    private mutating func appendLiteral(_ character: Character, into output: inout String) {
        literalTail.append(character)
        while let replacement = matchLiteralPattern(allowLookahead: false) {
            output.append(replacement)
        }
        flushTailIfNeeded(into: &output)
    }

    private mutating func flushColonBuffer(into output: inout String) {
        guard !colonBuffer.isEmpty else { return }
        for ch in colonBuffer {
            appendLiteral(ch, into: &output)
        }
        colonBuffer.removeAll(keepingCapacity: true)
        colonContent.removeAll(keepingCapacity: true)
    }

    private mutating func flushTailIfNeeded(into output: inout String) {
        guard !literalTail.isEmpty else { return }
        let keep = longestPendingPrefixLength()
        let flushCount = literalTail.count - keep
        guard flushCount > 0 else { return }
        let prefix = String(literalTail.prefix(flushCount))
        output.append(prefix)
        literalTail.removeFirst(flushCount)
    }

    private mutating func matchLiteralPattern(allowLookahead: Bool) -> String? {
        for pattern in literalPatterns {
            let length = pattern.characters.count
            guard length <= literalTail.count else { continue }
            if pattern.requiresLookahead && !allowLookahead && literalTail.count == length {
                continue
            }
            let candidate = literalTail.suffix(length)
            if candidate.elementsEqual(pattern.characters) {
                literalTail.removeLast(length)
                return pattern.replacement
            }
        }
        return nil
    }

    mutating func drainLiteralTail() -> String {
        guard !literalTail.isEmpty else { return "" }
        let drained = String(literalTail)
        literalTail.removeAll(keepingCapacity: true)
        return drained
    }

    mutating func flushPendingLiteralTail(into output: inout String) {
        guard !literalTail.isEmpty else { return }
        while let replacement = matchLiteralPattern(allowLookahead: true) {
            output.append(replacement)
        }
        if !literalTail.isEmpty {
            output.append(String(literalTail))
            literalTail.removeAll(keepingCapacity: true)
        }
    }

    private func longestPendingPrefixLength() -> Int {
        guard maxLiteralPatternLength > 1 else { return 0 }
        let maxLength = min(maxLiteralPatternLength - 1, literalTail.count)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = String(literalTail.suffix(length))
            if literalPrefixSet.contains(suffix) {
                return length
            }
        }
        return 0
    }

    private func isShortcodeInitial(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private func isShortcodeContinuation(_ character: Character) -> Bool {
        isShortcodeInitial(character)
    }
}
