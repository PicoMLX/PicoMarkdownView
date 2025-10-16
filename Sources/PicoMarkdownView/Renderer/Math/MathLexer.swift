import Foundation

enum MathToken: Equatable, Sendable {
    case symbol(String)
    case number(String)
    case command(String)
    case leftBrace
    case rightBrace
    case leftBracket
    case rightBracket
    case leftParen
    case rightParen
    case caret
    case underscore
    case ampersand
    case comma
    case newline
    case space(kind: MathSpaceKind)
    case textLiteral(String)
    case eof
}

enum MathSpaceKind: Sendable, Equatable {
    case thin
    case medium
    case quad
}

struct MathLexer {
    private let scalars: [UnicodeScalar]
    private var index: Int = 0

    init(string: String) {
        self.scalars = Array(string.unicodeScalars)
    }

    mutating func nextToken() -> MathToken {
        skipWhitespace()
        guard index < scalars.count else { return .eof }
        let scalar = scalars[index]
        switch scalar {
        case "{":
            index += 1
            return .leftBrace
        case "}":
            index += 1
            return .rightBrace
        case "[":
            index += 1
            return .leftBracket
        case "]":
            index += 1
            return .rightBracket
        case "(":
            index += 1
            return .leftParen
        case ")":
            index += 1
            return .rightParen
        case "^":
            index += 1
            return .caret
        case "_":
            index += 1
            return .underscore
        case "&":
            index += 1
            return .ampersand
        case ",":
            index += 1
            return .comma
        case "\\":
            return readEscape()
        default:
            if CharacterSet.decimalDigits.contains(scalar) {
                return readNumber()
            }
            if CharacterSet.letters.contains(scalar) || greekLetterScalars.contains(scalar) {
                return readIdentifier()
            }
            if scalar == "·" { // middot
                index += 1
                return .symbol("·")
            }
            index += 1
            return .symbol(String(scalar))
        }
    }

    private mutating func readIdentifier() -> MathToken {
        let start = index
        while index < scalars.count,
              CharacterSet.letters.contains(scalars[index]) || greekLetterScalars.contains(scalars[index]) {
            index += 1
        }
        let token = String(String.UnicodeScalarView(scalars[start..<index]))
        return .symbol(token)
    }

    private mutating func readNumber() -> MathToken {
        let start = index
        while index < scalars.count,
              CharacterSet.decimalDigits.contains(scalars[index]) || scalars[index] == "." {
            index += 1
        }
        let token = String(String.UnicodeScalarView(scalars[start..<index]))
        return .number(token)
    }

    private mutating func readEscape() -> MathToken {
        index += 1
        guard index < scalars.count else { return .eof }
        let scalar = scalars[index]
        if scalar == "\\" {
            index += 1
            return .newline
        }
        if scalar == " " {
            index += 1
            return .space(kind: .medium)
        }
        var commandScalars: [UnicodeScalar] = []
        while index < scalars.count {
            let current = scalars[index]
            if CharacterSet.letters.contains(current) {
                commandScalars.append(current)
                index += 1
                continue
            }
            break
        }
        let command = String(String.UnicodeScalarView(commandScalars))
        if command.isEmpty {
            // single-character command like \{ or \}
            let char = scalars[index]
            index += 1
            switch char {
            case "{": return .symbol("{")
            case "}": return .symbol("}")
            case "[": return .symbol("[")
            case "]": return .symbol("]")
            case "|": return .symbol("|")
            case "%":
                skipUntilLineEnd()
                return nextToken()
            default:
                return .symbol(String(char))
            }
        }
        switch command {
        case "", " ":
            return .space(kind: .medium)
        case ",":
            return .space(kind: .thin)
        case ";":
            return .space(kind: .medium)
        case "quad":
            return .space(kind: .quad)
        default:
            return .command(command)
        }
    }

    private mutating func skipWhitespace() {
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func skipUntilLineEnd() {
        while index < scalars.count && scalars[index] != "\n" {
            index += 1
        }
    }
}

private let greekLetterScalars: CharacterSet = {
    var set = CharacterSet()
    let greek = "αβγδεζηθικλμνξοπρστυφχψωΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"
    for scalar in greek.unicodeScalars {
        set.insert(scalar)
    }
    return set
}()
