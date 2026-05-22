import Foundation

public enum GraphQLInputValue: Sendable, Equatable {
    case omitted
    case null
    case value(GraphQLJSONValue)
}

public protocol GraphQLInputConvertible {
    func graphQLInputValue() throws -> GraphQLInputValue
}

public protocol GraphQLVariableMapConvertible {
    func graphQLVariableMap() throws -> [String: GraphQLJSONValue]
}

public struct GraphQLVariableBuilder {
    private var fields: [String: GraphQLJSONValue] = [:]

    public init() {}

    public mutating func set<Value: Encodable>(_ name: String, _ value: Value) throws {
        if let input = value as? any GraphQLInputConvertible {
            switch try input.graphQLInputValue() {
            case .omitted:
                return
            case .null:
                fields[name] = .null
            case .value(let json):
                fields[name] = json
            }
        } else {
            fields[name] = try GraphQLJSONEncoder.value(from: value)
        }
    }

    public func build() -> [String: GraphQLJSONValue] {
        fields
    }
}

public struct GraphQLInputObject: Encodable, Sendable, Equatable, GraphQLVariableMapConvertible {
    public var fields: [String: GraphQLJSONValue]

    public init(fields: [String: GraphQLJSONValue] = [:]) {
        self.fields = fields
    }

    public func graphQLVariableMap() throws -> [String: GraphQLJSONValue] {
        fields
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }
}

extension GraphQLNullable: GraphQLInputConvertible where Wrapped: Encodable {
    public func graphQLInputValue() throws -> GraphQLInputValue {
        switch self {
        case .none:
            return .omitted
        case .null:
            return .null
        case .some(let value):
            return .value(try GraphQLJSONEncoder.value(from: value))
        }
    }
}

public enum GraphQLJSONEncoder {
    public static func value<Value: Encodable>(from value: Value) throws -> GraphQLJSONValue {
        if let variableMap = value as? any GraphQLVariableMapConvertible {
            return .object(try variableMap.graphQLVariableMap())
        }
        let data = try JSONEncoder().encode(value)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try GraphQLJSONValue(jsonObject: jsonObject)
    }

    public static func variableObject<Value: Encodable & Sendable>(from value: Value) throws -> GraphQLJSONValue? {
        if Value.self == EmptyGraphQLVariables.self {
            return nil
        }
        if let variableMap = value as? any GraphQLVariableMapConvertible {
            let fields = try variableMap.graphQLVariableMap()
            return fields.isEmpty ? nil : .object(fields)
        }
        let json = try Self.value(from: value)
        if case .object(let fields) = json, fields.isEmpty {
            return nil
        }
        return json
    }
}
