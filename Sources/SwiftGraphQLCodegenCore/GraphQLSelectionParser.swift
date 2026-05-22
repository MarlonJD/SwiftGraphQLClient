import Foundation

struct GraphQLSelectionSet: Sendable, Equatable {
    var selections: [GraphQLSelection]
}

enum GraphQLSelection: Sendable, Equatable {
    case field(GraphQLSelectedField)
    case fragmentSpread(String)
    case inlineFragment(typeName: String?, selections: [GraphQLSelection])
}

struct GraphQLSelectedField: Sendable, Equatable {
    var name: String
    var responseName: String
    var selections: [GraphQLSelection]
}

enum GraphQLSelectionParser {
    static func parseSelectionSet(in source: String) throws -> GraphQLSelectionSet {
        guard let openBrace = source.firstIndex(of: "{") else {
            throw CodegenError.invalidOperation("Expected selection set.")
        }
        var parser = Parser(source: source, index: openBrace)
        return try parser.parseSelectionSet()
    }

    private struct Parser {
        let source: String
        var index: String.Index

        mutating func parseSelectionSet() throws -> GraphQLSelectionSet {
            guard consume("{") else {
                throw CodegenError.invalidOperation("Expected { in selection set.")
            }
            var selections: [GraphQLSelection] = []
            while true {
                skipIgnored()
                if consume("}") { break }
                if isAtEnd { break }
                selections.append(try parseSelection())
            }
            return GraphQLSelectionSet(selections: selections)
        }

        private mutating func parseSelection() throws -> GraphQLSelection {
            skipIgnored()
            if consume("...") {
                let name = parseName()
                if name == "on" {
                    let typeName = parseName()
                    skipIgnored()
                    while peek == "@" {
                        skipDirective()
                        skipIgnored()
                    }
                    let nested = try parseSelectionSet().selections
                    return .inlineFragment(typeName: typeName.isEmpty ? nil : typeName, selections: nested)
                }
                guard !name.isEmpty else {
                    throw CodegenError.invalidOperation("Expected fragment spread name.")
                }
                return .fragmentSpread(name)
            }

            let firstName = parseName()
            guard !firstName.isEmpty else {
                throw CodegenError.invalidOperation("Expected field name.")
            }

            skipIgnored()
            let responseName: String
            let fieldName: String
            if consume(":") {
                responseName = firstName
                fieldName = parseName()
            } else {
                responseName = firstName
                fieldName = firstName
            }

            skipIgnored()
            if peek == "(" {
                skipBalanced(open: "(", close: ")")
            }
            skipIgnored()
            while peek == "@" {
                skipDirective()
                skipIgnored()
            }

            let nested: [GraphQLSelection]
            if peek == "{" {
                nested = try parseSelectionSet().selections
            } else {
                nested = []
            }
            return .field(GraphQLSelectedField(name: fieldName, responseName: responseName, selections: nested))
        }

        private mutating func parseName() -> String {
            skipIgnored()
            var name = ""
            while !isAtEnd {
                let character = source[index]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                name.append(character)
                index = source.index(after: index)
            }
            return name
        }

        private mutating func skipDirective() {
            _ = consume("@")
            _ = parseName()
            skipIgnored()
            if peek == "(" {
                skipBalanced(open: "(", close: ")")
            }
        }

        private mutating func skipBalanced(open: Character, close: Character) {
            guard consume(open) else { return }
            var depth = 1
            var inString = false
            while !isAtEnd, depth > 0 {
                let character = source[index]
                index = source.index(after: index)
                if character == "\"" {
                    inString.toggle()
                } else if !inString, character == open {
                    depth += 1
                } else if !inString, character == close {
                    depth -= 1
                }
            }
        }

        private mutating func skipIgnored() {
            while !isAtEnd {
                let character = source[index]
                if character.isWhitespace || character == "," {
                    index = source.index(after: index)
                } else if character == "#" {
                    while !isAtEnd, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                } else {
                    break
                }
            }
        }

        private mutating func consume(_ text: String) -> Bool {
            skipIgnored()
            guard source[index...].hasPrefix(text) else { return false }
            index = source.index(index, offsetBy: text.count)
            return true
        }

        private mutating func consume(_ character: Character) -> Bool {
            skipIgnored()
            guard !isAtEnd, source[index] == character else { return false }
            index = source.index(after: index)
            return true
        }

        private var peek: Character? {
            var copy = self
            copy.skipIgnored()
            return copy.isAtEnd ? nil : copy.source[copy.index]
        }

        private var isAtEnd: Bool {
            index >= source.endIndex
        }
    }
}
