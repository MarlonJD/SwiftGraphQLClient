import Foundation

public struct GraphQLCachedResponse: Sendable, Equatable {
    public var data: GraphQLJSONValue?
    public var isPartial: Bool
    public var missingFields: [String]

    public init(
        data: GraphQLJSONValue?,
        isPartial: Bool = false,
        missingFields: [String] = []
    ) {
        self.data = data
        self.isPartial = isPartial
        self.missingFields = missingFields
    }
}

public protocol GraphQLOperationCache: Sendable {
    func read<Operation: GraphQLOperation>(_ operation: Operation) async throws -> GraphQLCachedResponse
    func write<Operation: GraphQLOperation>(_ operation: Operation, data: GraphQLJSONValue) async throws
}

public enum GraphQLOperationCacheKey {
    public static func key<Operation: GraphQLOperation>(for operation: Operation) throws -> String {
        let variables = try GraphQLJSONEncoder.variableObject(from: operation.variables)
        return "\(Operation.operationName):\(variables?.canonicalCacheKey ?? "{}")"
    }
}

public enum GraphQLResponseMaterializer {
    public static func decode<Data: Decodable>(
        _ type: Data.Type = Data.self,
        from value: GraphQLJSONValue,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        return try decoder.decode(Data.self, from: encoded)
    }
}

public extension GraphQLJSONValue {
    var canonicalCacheKey: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return "\"\(Self.escape(value))\""
        case .array(let values):
            return "[\(values.map(\.canonicalCacheKey).joined(separator: ","))]"
        case .object(let object):
            let fields = object.keys.sorted().map { key in
                "\"\(Self.escape(key))\":\(object[key]?.canonicalCacheKey ?? "null")"
            }
            return "{\(fields.joined(separator: ","))}"
        }
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
