import Foundation

struct GraphQLOperationDefinition: Sendable, Equatable {
    enum Kind: String, Sendable {
        case query
        case mutation
        case subscription
    }

    var kind: Kind
    var name: String
    var variables: [GraphQLVariableDefinition]
    var source: String
    var fragmentSpreads: Set<String>
}

struct GraphQLVariableDefinition: Sendable, Equatable {
    var name: String
    var type: GraphQLTypeReference
    var defaultValue: String?
}

struct GraphQLFragmentDefinition: Sendable, Equatable {
    var name: String
    var typeName: String
    var source: String
    var fragmentSpreads: Set<String>
}

struct GraphQLDocumentDefinitions: Sendable, Equatable {
    var operations: [GraphQLOperationDefinition]
    var fragments: [String: GraphQLFragmentDefinition]
}

enum GraphQLOperationParser {
    static func parseDocuments(_ texts: [String]) throws -> GraphQLDocumentDefinitions {
        var operations: [GraphQLOperationDefinition] = []
        var fragments: [String: GraphQLFragmentDefinition] = [:]

        for text in texts {
            let sources = GraphQLDefinitionSourceExtractor.extract(from: text)
            for source in sources {
                if let operation = try parseOperation(source) {
                    operations.append(operation)
                } else if let fragment = parseFragment(source) {
                    fragments[fragment.name] = fragment
                }
            }
        }

        return GraphQLDocumentDefinitions(operations: operations, fragments: fragments)
    }

    private static func parseOperation(_ source: String) throws -> GraphQLOperationDefinition? {
        let header = source.prefix { $0 != "{" }
        let words = header.split { $0.isWhitespace || $0 == "(" }
        guard let kindWord = words.first,
              let kind = GraphQLOperationDefinition.Kind(rawValue: String(kindWord)) else {
            return nil
        }
        guard words.count >= 2 else {
            throw CodegenError.invalidOperation("Anonymous operations are not supported.")
        }
        let name = String(words[1])
        let variableText = textInsideFirstParentheses(in: String(header))
        return GraphQLOperationDefinition(
            kind: kind,
            name: name,
            variables: try parseVariables(variableText),
            source: source.trimmingCharacters(in: .whitespacesAndNewlines),
            fragmentSpreads: fragmentSpreads(in: source)
        )
    }

    private static func parseFragment(_ source: String) -> GraphQLFragmentDefinition? {
        let header = source.prefix { $0 != "{" }
        let words = header.split { $0.isWhitespace }
        guard words.count >= 4, words[0] == "fragment", words[2] == "on" else { return nil }
        return GraphQLFragmentDefinition(
            name: String(words[1]),
            typeName: String(words[3]),
            source: source.trimmingCharacters(in: .whitespacesAndNewlines),
            fragmentSpreads: fragmentSpreads(in: source)
        )
    }

    private static func parseVariables(_ text: String?) throws -> [GraphQLVariableDefinition] {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try splitTopLevel(text, separator: ",").map { raw in
            var item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.hasPrefix("$"), let colon = item.firstIndex(of: ":") else {
                throw CodegenError.invalidOperation("Invalid variable definition: \(raw)")
            }
            let name = String(item[item.index(after: item.startIndex)..<colon])
                .trimmingCharacters(in: .whitespaces)
            item = String(item[item.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let defaultValue: String?
            if let equal = item.firstIndex(of: "=") {
                defaultValue = String(item[item.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                item = String(item[..<equal]).trimmingCharacters(in: .whitespaces)
            } else {
                defaultValue = nil
            }
            return GraphQLVariableDefinition(
                name: name,
                type: try GraphQLTypeReferenceParser.parse(item),
                defaultValue: defaultValue
            )
        }
    }

    static func fragmentSpreads(in source: String) -> Set<String> {
        let pattern = #"\.\.\.\s*(?!on\b)([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }

    private static func textInsideFirstParentheses(in text: String) -> String? {
        guard let start = text.firstIndex(of: "(") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: start)..<index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "[" || character == "(" || character == "{" {
                depth += 1
            } else if character == "]" || character == ")" || character == "}" {
                depth -= 1
            }
            if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts
    }
}

enum GraphQLDefinitionSourceExtractor {
    static func extract(from text: String) -> [String] {
        let pattern = #"(?m)^\s*((query|mutation|subscription)\s+[A-Za-z_][A-Za-z0-9_]*|fragment\s+[A-Za-z_][A-Za-z0-9_]*)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let start = Range(match.range, in: text)?.lowerBound,
                  let openBrace = text[start...].firstIndex(of: "{") else {
                return nil
            }
            var depth = 0
            var index = openBrace
            while index < text.endIndex {
                let character = text[index]
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
                index = text.index(after: index)
            }
            return nil
        }
    }
}
