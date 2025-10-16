import Foundation

indirect enum MathNode: Sendable {
    case sequence([MathNode])
    case symbol(String, MathSymbolStyle)
    case number(String)
    case operatorToken(String)
    case function(String)
    case fraction(MathNode, MathNode)
    case sqrt(body: MathNode, index: MathNode?)
    case scripts(base: MathNode, superscript: MathNode?, subscript: MathNode?)
    case delimiter(left: MathDelimiter, body: MathNode, right: MathDelimiter)
    case matrix(style: MathMatrixStyle, rows: [[MathNode]])
    case text(String)
    case spacing(MathSpaceKind)
    case accent(kind: MathAccentKind, base: MathNode)
    case binomial(top: MathNode, bottom: MathNode)
    case cases(rows: [(condition: MathNode, result: MathNode)])
    case aligned(rows: [[MathNode]])
}

enum MathSymbolStyle: Sendable {
    case italic
    case upright
    case bold
}

enum MathAccentKind: Sendable {
    case hat
    case bar
    case overline
    case vec
}

enum MathMatrixStyle: Sendable {
    case matrix
    case pmatrix
}

enum MathDelimiter: Sendable {
    case parenthesisLeft
    case parenthesisRight
    case bracketLeft
    case bracketRight
    case braceLeft
    case braceRight
    case vertical
    case doubleVertical
    case angleLeft
    case angleRight
    case none

    static func from(command: String, isLeft: Bool) -> MathDelimiter? {
        switch command {
        case "(": return isLeft ? .parenthesisLeft : .parenthesisRight
        case ")": return .parenthesisRight
        case "[": return isLeft ? .bracketLeft : .bracketRight
        case "]": return .bracketRight
        case "{": return .braceLeft
        case "}": return .braceRight
        case "\\{": return .braceLeft
        case "\\}": return .braceRight
        case "lvert": return .vertical
        case "rvert": return .vertical
        case "lVert": return .doubleVertical
        case "rVert": return .doubleVertical
        case "langle": return .angleLeft
        case "rangle": return .angleRight
        case "|": return .vertical
        case ".": return MathDelimiter.none
        default:
            return nil
        }
    }
}

struct MathParser {
    private var lexer: MathLexer
    private var lookahead: MathToken

    init(string: String) {
        var lexer = MathLexer(string: string)
        self.lookahead = lexer.nextToken()
        self.lexer = lexer
    }

    mutating func parse() throws -> MathNode {
        let expr = try parseSequence(terminators: [.eof, .rightBrace, .rightBracket, .rightParen])
        return expr
    }

    private mutating func parseSequence(terminators: [MathToken]) throws -> MathNode {
        var nodes: [MathNode] = []
        while !terminators.contains(where: { $0.matches(lookahead) }) {
            if case .newline = lookahead {
                consume()
                nodes.append(.spacing(.medium))
                continue
            }
            if case .space(let kind) = lookahead {
                consume()
                nodes.append(.spacing(kind))
                continue
            }
            nodes.append(try parsePrimary())
        }
        if nodes.count == 1 {
            return nodes[0]
        }
        return .sequence(nodes)
    }

    private mutating func parsePrimary() throws -> MathNode {
        let node: MathNode
        switch lookahead {
        case .symbol(let value):
            consume()
            node = classifySymbol(value)
        case .number(let value):
            consume()
            node = .number(value)
        case .command(let name):
            node = try parseCommand(name)
        case .leftBrace:
            consume()
            let content = try parseSequence(terminators: [.rightBrace])
            try expect(.rightBrace)
            node = content
        case .leftParen:
            consume()
            let content = try parseSequence(terminators: [.rightParen])
            try expect(.rightParen)
            node = .delimiter(left: .parenthesisLeft, body: content, right: .parenthesisRight)
        case .leftBracket:
            consume()
            let content = try parseSequence(terminators: [.rightBracket])
            try expect(.rightBracket)
            node = .delimiter(left: .bracketLeft, body: content, right: .bracketRight)
        default:
            throw MathRenderError.parseFailure("Unexpected token: \(lookahead)")
        }

        return try parsePostfix(base: node)
    }

    private mutating func parsePostfix(base: MathNode) throws -> MathNode {
        var current = base
        while true {
            switch lookahead {
            case .caret:
                consume()
                let superscript = try parseSupSubArgument()
                var subscriptNode: MathNode? = nil
                if case .underscore = lookahead {
                    consume()
                    subscriptNode = try parseSupSubArgument()
                }
                current = .scripts(base: current, superscript: superscript, subscript: subscriptNode)
            case .underscore:
                consume()
                let subscriptNode = try parseSupSubArgument()
                var superscript: MathNode? = nil
                if case .caret = lookahead {
                    consume()
                    superscript = try parseSupSubArgument()
                }
                current = .scripts(base: current, superscript: superscript, subscript: subscriptNode)
            default:
                return current
            }
        }
    }

    private mutating func parseSupSubArgument() throws -> MathNode {
        if lookahead == .leftBrace {
            consume()
            let content = try parseSequence(terminators: [.rightBrace])
            try expect(.rightBrace)
            return content
        }
        return try parsePrimary()
    }

    private mutating func parseCommand(_ name: String) throws -> MathNode {
        consume()
        switch name {
        case "frac":
            let numerator = try parseRequiredGroup()
            let denominator = try parseRequiredGroup()
            return .fraction(numerator, denominator)
        case "sqrt":
            var indexNode: MathNode? = nil
            if lookahead == .leftBracket {
                consume()
                indexNode = try parseSequence(terminators: [.rightBracket])
                try expect(.rightBracket)
            }
            let body = try parseRequiredGroup()
            return .sqrt(body: body, index: indexNode)
        case "binom":
            let top = try parseRequiredGroup()
            let bottom = try parseRequiredGroup()
            return .binomial(top: top, bottom: bottom)
        case "text":
            let content = try parseTextGroup()
            return .text(content)
        case "left":
            let leftSymbol = try readDelimiter(isLeft: true)
            let inner = try parseSequence(terminators: [.command("right")])
            guard case .command("right") = lookahead else {
                throw MathRenderError.parseFailure("Missing \\right for delimiter pair")
            }
            consume()
            let rightSymbol = try readDelimiter(isLeft: false)
            return .delimiter(left: leftSymbol, body: inner, right: rightSymbol)
        case "begin":
            let envName = try parseEnvironmentName()
            switch envName {
            case "cases":
                return try parseCasesEnvironment()
            case "aligned":
                return try parseAlignedEnvironment()
            case "matrix":
                return try parseMatrixEnvironment(style: .matrix)
            case "pmatrix":
                return try parseMatrixEnvironment(style: .pmatrix)
            default:
                throw MathRenderError.unsupportedCommand(envName)
            }
        case "hat":
            let base = try parseRequiredGroup()
            return .accent(kind: .hat, base: base)
        case "bar":
            let base = try parseRequiredGroup()
            return .accent(kind: .bar, base: base)
        case "overline":
            let base = try parseRequiredGroup()
            return .accent(kind: .overline, base: base)
        case "vec":
            let base = try parseRequiredGroup()
            return .accent(kind: .vec, base: base)
        case "mathrm":
            let body = try parseRequiredGroup()
            return applySymbolStyle(body, style: .upright)
        case "mathbf":
            let body = try parseRequiredGroup()
            return applySymbolStyle(body, style: .bold)
        case "mathit":
            let body = try parseRequiredGroup()
            return applySymbolStyle(body, style: .italic)
        case "sum", "prod", "int", "lim",
             "sin", "cos", "tan", "log", "ln":
            if largeOperatorNames.contains(name) {
                return .operatorToken(name)
            }
            return .function(name)
        case "le", "ge", "neq", "approx", "in", "subseteq", "supseteq",
             "cup", "cap", "to", "implies", "iff", "infty", "cdot", "ldots", "cdots", "dots":
            return .operatorToken(name)
        default:
            throw MathRenderError.unsupportedCommand(name)
        }
    }

    private mutating func parseRequiredGroup() throws -> MathNode {
        guard lookahead == .leftBrace else {
            throw MathRenderError.parseFailure("Expected group")
        }
        consume()
        let content = try parseSequence(terminators: [.rightBrace])
        try expect(.rightBrace)
        return content
    }

    private mutating func parseTextGroup() throws -> String {
        guard lookahead == .leftBrace else {
            throw MathRenderError.parseFailure("Expected { for \\text")
        }
        consume()
        var scalars: [UnicodeScalar] = []
        while lookahead != .rightBrace && lookahead != .eof {
            switch lookahead {
            case .symbol(let value):
                scalars.append(contentsOf: value.unicodeScalars)
            case .number(let value):
                scalars.append(contentsOf: value.unicodeScalars)
            case .space:
                scalars.append(" ")
            default:
                throw MathRenderError.parseFailure("Unsupported token inside \\text")
            }
            consume()
        }
        try expect(.rightBrace)
        return String(String.UnicodeScalarView(scalars))
    }

    private mutating func parseEnvironmentName() throws -> String {
        guard lookahead == .leftBrace else {
            throw MathRenderError.parseFailure("Expected { after \\begin")
        }
        consume()
        guard case .symbol(let name) = lookahead else {
            throw MathRenderError.parseFailure("Expected environment name")
        }
        consume()
        try expect(.rightBrace)
        return name
    }

    private mutating func parseCasesEnvironment() throws -> MathNode {
        var rows: [(MathNode, MathNode)] = []
        while true {
            if lookahead == .command("end") {
                consume(); try expectEnvironmentEnd("cases"); break
            }
            let left = try parseSequence(terminators: [.ampersand, .command("end"), .newline])
            var right = MathNode.sequence([])
            if lookahead == .ampersand {
                consume()
                right = try parseSequence(terminators: [.command("end"), .newline])
            }
            rows.append((left, right))
            if lookahead == .newline { consume() }
        }
        return .cases(rows: rows)
    }

    private mutating func parseAlignedEnvironment() throws -> MathNode {
        var rows: [[MathNode]] = []
        while true {
            if lookahead == .command("end") {
                consume(); try expectEnvironmentEnd("aligned"); break
            }
            var row: [MathNode] = []
            row.append(try parseSequence(terminators: [.ampersand, .newline, .command("end")]))
            while lookahead == .ampersand {
                consume()
                row.append(try parseSequence(terminators: [.ampersand, .newline, .command("end")]))
            }
            rows.append(row)
            if lookahead == .newline { consume() }
        }
        return .aligned(rows: rows)
    }

    private mutating func parseMatrixEnvironment(style: MathMatrixStyle) throws -> MathNode {
        var rows: [[MathNode]] = []
        while true {
            if lookahead == .command("end") {
                consume();
                try expectEnvironmentEnd(style == .matrix ? "matrix" : "pmatrix")
                break
            }
            var row: [MathNode] = []
            row.append(try parseSequence(terminators: [.ampersand, .newline, .command("end")]))
            while lookahead == .ampersand {
                consume()
                row.append(try parseSequence(terminators: [.ampersand, .newline, .command("end")]))
            }
            rows.append(row)
            if lookahead == .newline { consume() }
        }
        return .matrix(style: style, rows: rows)
    }

    private mutating func readDelimiter(isLeft: Bool) throws -> MathDelimiter {
        switch lookahead {
        case .symbol(let value):
            consume()
            if let delimiter = MathDelimiter.from(command: value, isLeft: isLeft) {
                return delimiter
            }
        case .command(let name):
            consume()
            if let delimiter = MathDelimiter.from(command: name, isLeft: isLeft) {
                return delimiter
            }
        default:
            break
        }
        throw MathRenderError.parseFailure("Unsupported delimiter")
    }

    private mutating func expect(_ token: MathToken) throws {
        guard lookahead.matches(token) else {
            throw MathRenderError.parseFailure("Expected token \(token), got \(lookahead)")
        }
        consume()
    }

    private mutating func expectEnvironmentEnd(_ name: String) throws {
        guard lookahead == .leftBrace else {
            throw MathRenderError.parseFailure("Expected { after \\end")
        }
        consume()
        guard case .symbol(let identifier) = lookahead, identifier == name else {
            throw MathRenderError.parseFailure("Environment mismatch: expected \(name)")
        }
        consume()
        try expect(.rightBrace)
    }

    private mutating func consume() {
        lookahead = lexer.nextToken()
    }

    private func classifySymbol(_ value: String) -> MathNode {
        if operatorSymbols.contains(value) {
            return .operatorToken(value)
        }
        if specialSymbolMap.keys.contains(value) {
            return .symbol(specialSymbolMap[value] ?? value, .upright)
        }
        if value.count == 1 && CharacterSet.letters.contains(value.unicodeScalars.first!) {
            return .symbol(value, .italic)
        }
        return .symbol(value, .upright)
    }
}

private let operatorSymbols: Set<String> = [
    "+", "-", "=", "<", ">", "<=", ">=", "≠", "≈", "·", "→", "⇒", "⇔",
    "∈", "⊂", "⊆", "⊃", "⊇", "∪", "∩", "∞"
]

private let largeOperatorNames: Set<String> = ["sum", "prod", "int", "lim"]

private let specialSymbolMap: [String: String] = [
    "le": "≤",
    "ge": "≥",
    "neq": "≠",
    "approx": "≈",
    "in": "∈",
    "subseteq": "⊆",
    "supseteq": "⊇",
    "cup": "∪",
    "cap": "∩",
    "to": "→",
    "implies": "⇒",
    "iff": "⇔",
    "infty": "∞",
    "cdot": "·",
    "ldots": "…",
    "cdots": "⋯",
    "dots": "…"
]

private extension MathToken {
    func matches(_ other: MathToken) -> Bool {
        switch (self, other) {
        case (.leftBrace, .leftBrace), (.rightBrace, .rightBrace), (.leftBracket, .leftBracket), (.rightBracket, .rightBracket),
             (.leftParen, .leftParen), (.rightParen, .rightParen), (.caret, .caret), (.underscore, .underscore), (.ampersand, .ampersand),
             (.comma, .comma), (.newline, .newline), (.eof, .eof):
            return true
        case (.command(let lhs), .command(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

private func applySymbolStyle(_ node: MathNode, style: MathSymbolStyle) -> MathNode {
    switch node {
    case .sequence(let nodes):
        return .sequence(nodes.map { applySymbolStyle($0, style: style) })
    case .symbol(let value, _):
        return .symbol(value, style)
    case .number:
        return node
    case .operatorToken:
        return node
    case .function:
        return node
    case .fraction(let lhs, let rhs):
        return .fraction(applySymbolStyle(lhs, style: style), applySymbolStyle(rhs, style: style))
    case .sqrt(let body, let index):
        return .sqrt(body: applySymbolStyle(body, style: style), index: index.map { applySymbolStyle($0, style: style) })
    case .scripts(let base, let sup, let sub):
        return .scripts(base: applySymbolStyle(base, style: style), superscript: sup.map { applySymbolStyle($0, style: style) }, subscript: sub.map { applySymbolStyle($0, style: style) })
    case .delimiter(let left, let body, let right):
        return .delimiter(left: left, body: applySymbolStyle(body, style: style), right: right)
    case .matrix(let matrixStyle, let rows):
        let mapped = rows.map { $0.map { applySymbolStyle($0, style: style) } }
        return .matrix(style: matrixStyle, rows: mapped)
    case .text:
        return node
    case .spacing:
        return node
    case .accent(let kind, let base):
        return .accent(kind: kind, base: applySymbolStyle(base, style: style))
    case .binomial(let top, let bottom):
        return .binomial(top: applySymbolStyle(top, style: style), bottom: applySymbolStyle(bottom, style: style))
    case .cases(let rows):
        let mapped = rows.map { (applySymbolStyle($0.condition, style: style), applySymbolStyle($0.result, style: style)) }
        return .cases(rows: mapped)
    case .aligned(let rows):
        return .aligned(rows: rows.map { $0.map { applySymbolStyle($0, style: style) } })
    }
}
