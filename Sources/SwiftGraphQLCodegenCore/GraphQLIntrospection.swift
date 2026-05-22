import Foundation
import SwiftGraphQLClient

public enum GraphQLIntrospection {
    public static let query = """
    query IntrospectionQuery {
      __schema {
        queryType { name }
        mutationType { name }
        subscriptionType { name }
        directives {
          name
          locations
          isRepeatable
          args {
            name
            type { ...TypeRef }
            defaultValue
          }
        }
        types {
          kind
          name
          fields(includeDeprecated: true) {
            name
            args {
              name
              type { ...TypeRef }
              defaultValue
            }
            type { ...TypeRef }
          }
          inputFields {
            name
            type { ...TypeRef }
            defaultValue
          }
          interfaces { ...TypeRef }
          enumValues(includeDeprecated: true) {
            name
          }
          possibleTypes { ...TypeRef }
        }
      }
    }

    fragment TypeRef on __Type {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
                ofType {
                  kind
                  name
                  ofType {
                    kind
                    name
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    public static func schemaSDL(from responseData: Data) throws -> String {
        if let response = try? JSONDecoder().decode(IntrospectionResponse.self, from: responseData),
           let schema = response.data?.schema {
            return IntrospectionSDLPrinter(schema: schema).print()
        }

        let rawSchema = try JSONDecoder().decode(IntrospectionRawSchema.self, from: responseData).schema
        return IntrospectionSDLPrinter(schema: rawSchema).print()
    }
}

private struct IntrospectionResponse: Decodable {
    struct DataContainer: Decodable {
        let schema: IntrospectionSchema

        enum CodingKeys: String, CodingKey {
            case schema = "__schema"
        }
    }

    let data: DataContainer?
    let errors: [GraphQLError]?
}

private struct IntrospectionRawSchema: Decodable {
    let schema: IntrospectionSchema

    enum CodingKeys: String, CodingKey {
        case schema = "__schema"
    }
}

private struct IntrospectionSchema: Decodable {
    let queryType: IntrospectionNamedType
    let mutationType: IntrospectionNamedType?
    let subscriptionType: IntrospectionNamedType?
    let directives: [IntrospectionDirective]?
    let types: [IntrospectionType]
}

private struct IntrospectionNamedType: Decodable {
    let name: String
}

private struct IntrospectionDirective: Decodable {
    let name: String
    let locations: [String]
    let isRepeatable: Bool?
    let args: [IntrospectionInputValue]?
}

private struct IntrospectionType: Decodable {
    let kind: String
    let name: String?
    let fields: [IntrospectionField]?
    let inputFields: [IntrospectionInputValue]?
    let interfaces: [IntrospectionTypeReference]?
    let enumValues: [IntrospectionEnumValue]?
    let possibleTypes: [IntrospectionTypeReference]?
}

private struct IntrospectionField: Decodable {
    let name: String
    let args: [IntrospectionInputValue]?
    let type: IntrospectionTypeReference
}

private struct IntrospectionInputValue: Decodable {
    let name: String
    let type: IntrospectionTypeReference
    let defaultValue: String?
}

private struct IntrospectionEnumValue: Decodable {
    let name: String
}

private indirect enum IntrospectionTypeReference: Decodable {
    case named(kind: String, name: String)
    case list(IntrospectionTypeReference)
    case nonNull(IntrospectionTypeReference)

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case ofType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let ofType = try container.decodeIfPresent(IntrospectionTypeReference.self, forKey: .ofType)

        switch kind {
        case "NON_NULL":
            guard let ofType else {
                throw CodegenError.invalidSchema("Introspection NON_NULL type is missing ofType.")
            }
            self = .nonNull(ofType)
        case "LIST":
            guard let ofType else {
                throw CodegenError.invalidSchema("Introspection LIST type is missing ofType.")
            }
            self = .list(ofType)
        default:
            guard let name else {
                throw CodegenError.invalidSchema("Introspection named type is missing name.")
            }
            self = .named(kind: kind, name: name)
        }
    }

    var namedTypeName: String? {
        switch self {
        case .named(_, let name):
            return name
        case .list(let type), .nonNull(let type):
            return type.namedTypeName
        }
    }
}

private struct IntrospectionSDLPrinter {
    private static let builtInScalars: Set<String> = ["String", "Int", "Float", "Boolean", "ID"]

    let schema: IntrospectionSchema

    func print() -> String {
        let visibleTypes = schema.types
            .filter { type in
                guard let name = type.name else { return false }
                return !name.hasPrefix("__")
            }
        let typesByKind = Dictionary(grouping: visibleTypes, by: \.kind)
        var sections: [String] = []

        if let schemaBlock = schemaDefinition() {
            sections.append(schemaBlock)
        }
        sections.append(contentsOf: directiveDefinitions())
        sections.append(contentsOf: scalarDefinitions(typesByKind["SCALAR"] ?? []))
        sections.append(contentsOf: enumDefinitions(typesByKind["ENUM"] ?? []))
        sections.append(contentsOf: inputObjectDefinitions(typesByKind["INPUT_OBJECT"] ?? []))
        sections.append(contentsOf: interfaceDefinitions(typesByKind["INTERFACE"] ?? []))
        sections.append(contentsOf: unionDefinitions(typesByKind["UNION"] ?? []))
        sections.append(contentsOf: objectDefinitions(typesByKind["OBJECT"] ?? []))

        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private func schemaDefinition() -> String? {
        let operations = [
            ("query", schema.queryType.name, "Query"),
            ("mutation", schema.mutationType?.name, "Mutation"),
            ("subscription", schema.subscriptionType?.name, "Subscription")
        ].compactMap { operation, typeName, defaultName -> String? in
            guard let typeName, typeName != defaultName else { return nil }
            return "  \(operation): \(typeName)"
        }

        guard !operations.isEmpty else { return nil }
        return (["schema {"] + operations + ["}"]).joined(separator: "\n")
    }

    private func directiveDefinitions() -> [String] {
        (schema.directives ?? [])
            .filter { !$0.name.hasPrefix("__") }
            .sorted { $0.name < $1.name }
            .map { directive in
                let args = argumentList(directive.args ?? [])
                let repeatable = directive.isRepeatable == true ? " repeatable" : ""
                let locations = directive.locations.sorted().joined(separator: " | ")
                return "directive @\(directive.name)\(args)\(repeatable) on \(locations)"
            }
    }

    private func scalarDefinitions(_ types: [IntrospectionType]) -> [String] {
        types
            .compactMap(\.name)
            .filter { !Self.builtInScalars.contains($0) }
            .sorted()
            .map { "scalar \($0)" }
    }

    private func enumDefinitions(_ types: [IntrospectionType]) -> [String] {
        namedTypes(types).map { type in
            let values = (type.enumValues ?? [])
                .map { "  \($0.name)" }
            return (["enum \(type.name!) {"] + values + ["}"]).joined(separator: "\n")
        }
    }

    private func inputObjectDefinitions(_ types: [IntrospectionType]) -> [String] {
        namedTypes(types).map { type in
            let fields = (type.inputFields ?? [])
                .map { "  \($0.name): \(render($0.type))\(defaultValueSuffix($0.defaultValue))" }
            return (["input \(type.name!) {"] + fields + ["}"]).joined(separator: "\n")
        }
    }

    private func interfaceDefinitions(_ types: [IntrospectionType]) -> [String] {
        namedTypes(types).map { type in
            let fields = (type.fields ?? []).map(fieldLine)
            return (["interface \(type.name!) {"] + fields + ["}"]).joined(separator: "\n")
        }
    }

    private func unionDefinitions(_ types: [IntrospectionType]) -> [String] {
        namedTypes(types).map { type in
            let members = (type.possibleTypes ?? [])
                .compactMap(\.namedTypeName)
                .sorted()
                .joined(separator: " | ")
            return "union \(type.name!) = \(members)"
        }
    }

    private func objectDefinitions(_ types: [IntrospectionType]) -> [String] {
        namedTypes(types).map { type in
            let interfaces = (type.interfaces ?? [])
                .compactMap(\.namedTypeName)
                .sorted()
            let implements = interfaces.isEmpty ? "" : " implements \(interfaces.joined(separator: " & "))"
            let fields = (type.fields ?? []).map(fieldLine)
            return (["type \(type.name!)\(implements) {"] + fields + ["}"]).joined(separator: "\n")
        }
    }

    private func namedTypes(_ types: [IntrospectionType]) -> [IntrospectionType] {
        types
            .filter { $0.name != nil }
            .sorted { $0.name! < $1.name! }
    }

    private func fieldLine(_ field: IntrospectionField) -> String {
        "  \(field.name)\(argumentList(field.args ?? [])): \(render(field.type))"
    }

    private func argumentList(_ args: [IntrospectionInputValue]) -> String {
        guard !args.isEmpty else { return "" }
        let rendered = args
            .map { "\($0.name): \(render($0.type))\(defaultValueSuffix($0.defaultValue))" }
            .joined(separator: ", ")
        return "(\(rendered))"
    }

    private func defaultValueSuffix(_ defaultValue: String?) -> String {
        guard let defaultValue, !defaultValue.isEmpty else { return "" }
        return " = \(defaultValue)"
    }

    private func render(_ type: IntrospectionTypeReference) -> String {
        switch type {
        case .named(_, let name):
            return name
        case .list(let wrapped):
            return "[\(render(wrapped))]"
        case .nonNull(let wrapped):
            return "\(render(wrapped))!"
        }
    }
}
