import Foundation

struct GraphQLSchema: Sendable, Equatable {
    var scalars: Set<String> = ["String", "Int", "Float", "Boolean", "ID"]
    var enums: [String: GraphQLEnumDefinition] = [:]
    var inputObjects: [String: GraphQLInputObjectDefinition] = [:]
    var objects: [String: GraphQLObjectDefinition] = [:]
}

struct GraphQLEnumDefinition: Sendable, Equatable {
    var name: String
    var cases: [String]
}

struct GraphQLInputObjectDefinition: Sendable, Equatable {
    var name: String
    var fields: [GraphQLInputFieldDefinition]
}

struct GraphQLInputFieldDefinition: Sendable, Equatable {
    var name: String
    var type: GraphQLTypeReference
}

struct GraphQLObjectDefinition: Sendable, Equatable {
    var name: String
    var fields: [String: GraphQLFieldDefinition]
}

struct GraphQLFieldDefinition: Sendable, Equatable {
    var name: String
    var type: GraphQLTypeReference
}

indirect enum GraphQLTypeReference: Sendable, Equatable {
    case named(String)
    case list(GraphQLTypeReference)
    case nonNull(GraphQLTypeReference)

    var nullable: Bool {
        if case .nonNull = self { return false }
        return true
    }

    var unwrapped: GraphQLTypeReference {
        if case .nonNull(let inner) = self {
            return inner
        }
        return self
    }

    var namedType: String {
        switch self {
        case .named(let name):
            return name
        case .list(let inner), .nonNull(let inner):
            return inner.namedType
        }
    }
}

enum GraphQLSchemaParser {
    static func parse(_ text: String) throws -> GraphQLSchema {
        var schema = GraphQLSchema()
        let lines = text.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("scalar ") {
                if let name = line.components(separatedBy: .whitespaces).dropFirst().first {
                    schema.scalars.insert(name)
                }
                index += 1
                continue
            }

            if let enumName = blockName(line: line, keyword: "enum") {
                let (body, nextIndex) = collectBlock(lines: lines, startIndex: index)
                schema.enums[enumName] = GraphQLEnumDefinition(
                    name: enumName,
                    cases: body.compactMap { enumCaseName(from: $0) }
                )
                index = nextIndex
                continue
            }

            if let inputName = blockName(line: line, keyword: "input") {
                let (body, nextIndex) = collectBlock(lines: lines, startIndex: index)
                schema.inputObjects[inputName] = GraphQLInputObjectDefinition(
                    name: inputName,
                    fields: try body.compactMap(parseInputField)
                )
                index = nextIndex
                continue
            }

            if let objectName = blockName(line: line, keyword: "type") {
                let (body, nextIndex) = collectBlock(lines: lines, startIndex: index)
                let fields = try body.compactMap(parseObjectField)
                schema.objects[objectName] = GraphQLObjectDefinition(
                    name: objectName,
                    fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
                )
                index = nextIndex
                continue
            }

            index += 1
        }

        return schema
    }

    private static func blockName(line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword + " ") else { return nil }
        return line.dropFirst(keyword.count)
            .trimmingCharacters(in: .whitespaces)
            .split { $0 == " " || $0 == "{" || $0 == "@" }
            .first
            .map(String.init)
    }

    private static func collectBlock(lines: [String], startIndex: Int) -> ([String], Int) {
        var depth = 0
        var body: [String] = []
        var started = false
        var index = startIndex

        while index < lines.count {
            let line = stripComment(lines[index])
            var current = ""
            var lineIndex = line.startIndex
            while lineIndex < line.endIndex {
                let character = line[lineIndex]
                if character == "{" {
                    if started, depth > 0 {
                        current.append(character)
                    }
                    depth += 1
                    started = true
                } else if character == "}" {
                    if depth > 1 {
                        current.append(character)
                    }
                    depth -= 1
                    if started, depth <= 0 {
                        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            body.append(current)
                        }
                        return (body, index + 1)
                    }
                } else if started, depth > 0 {
                    current.append(character)
                }
                lineIndex = line.index(after: lineIndex)
            }
            if started, depth > 0, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body.append(current)
            }
            index += 1
        }
        return (body, index)
    }

    private static func enumCaseName(from line: String) -> String? {
        let value = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("@") else { return nil }
        return value.split { $0 == " " || $0 == "@" }.first.map(String.init)
    }

    private static func parseInputField(_ line: String) throws -> GraphQLInputFieldDefinition? {
        let line = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, let colon = topLevelColon(in: line) else { return nil }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var typeText = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if let equal = typeText.firstIndex(of: "=") {
            typeText = String(typeText[..<equal]).trimmingCharacters(in: .whitespaces)
        }
        if let directive = typeText.firstIndex(of: "@") {
            typeText = String(typeText[..<directive]).trimmingCharacters(in: .whitespaces)
        }
        return GraphQLInputFieldDefinition(name: name, type: try GraphQLTypeReferenceParser.parse(typeText))
    }

    private static func parseObjectField(_ line: String) throws -> GraphQLFieldDefinition? {
        let line = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, let colon = topLevelColon(in: line) else { return nil }
        let signature = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let name = signature.split { $0 == "(" || $0.isWhitespace }.first.map(String.init) ?? signature
        var typeText = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if let directive = typeText.firstIndex(of: "@") {
            typeText = String(typeText[..<directive]).trimmingCharacters(in: .whitespaces)
        }
        return GraphQLFieldDefinition(name: name, type: try GraphQLTypeReferenceParser.parse(typeText))
    }

    private static func topLevelColon(in line: String) -> String.Index? {
        var depth = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                depth -= 1
            } else if character == ":", depth == 0 {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
}

enum GraphQLTypeReferenceParser {
    static func parse(_ text: String) throws -> GraphQLTypeReference {
        var parser = Parser(text: text)
        return try parser.parseType()
    }

    private struct Parser {
        var characters: [Character]
        var index = 0

        init(text: String) {
            characters = Array(text.trimmingCharacters(in: .whitespaces))
        }

        mutating func parseType() throws -> GraphQLTypeReference {
            skipWhitespace()
            let type: GraphQLTypeReference
            if consume("[") {
                type = .list(try parseType())
                guard consume("]") else {
                    throw CodegenError.invalidSchema("Expected closing ] in GraphQL type.")
                }
            } else {
                type = .named(parseName())
            }
            skipWhitespace()
            if consume("!") {
                return .nonNull(type)
            }
            return type
        }

        private mutating func parseName() -> String {
            var name = ""
            while index < characters.count {
                let character = characters[index]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                name.append(character)
                index += 1
            }
            return name
        }

        private mutating func consume(_ expected: Character) -> Bool {
            skipWhitespace()
            guard index < characters.count, characters[index] == expected else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        }
    }
}
