import Foundation

public struct GraphQLID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            rawValue = string
        } else if let int = try? container.decode(Int.self) {
            rawValue = String(int)
        } else {
            throw DecodingError.typeMismatch(
                GraphQLID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer GraphQL ID.")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum GraphQLJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([GraphQLJSONValue])
    case object([String: GraphQLJSONValue])
}

public typealias GraphQLJSON = GraphQLJSONValue

extension GraphQLJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([GraphQLJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: GraphQLJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public extension GraphQLJSONValue {
    init(jsonObject: Any) throws {
        switch jsonObject {
        case _ as NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(Int64(value))
        case let value as Int64:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(GraphQLJSONValue.init(jsonObject:)))
        case let value as [String: Any]:
            var object: [String: GraphQLJSONValue] = [:]
            object.reserveCapacity(value.count)
            for (key, rawValue) in value {
                object[key] = try GraphQLJSONValue(jsonObject: rawValue)
            }
            self = .object(object)
        default:
            throw EncodingError.invalidValue(
                jsonObject,
                EncodingError.Context(codingPath: [], debugDescription: "Unsupported GraphQL JSON value.")
            )
        }
    }

    var objectValue: [String: GraphQLJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return Int(value)
        case .double(let value) where value.rounded() == value:
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
}

public struct GraphQLEnum<EnumType>: Codable, Hashable, Sendable where EnumType: RawRepresentable & Sendable, EnumType.RawValue == String {
    public let value: EnumType?
    public let rawValue: String

    public init(_ value: EnumType) {
        self.value = value
        self.rawValue = value.rawValue
    }

    public init(_ rawValue: String) {
        self.value = EnumType(rawValue: rawValue)
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func == (lhs: GraphQLEnum<EnumType>, rhs: GraphQLEnum<EnumType>) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

public enum GraphQLNullable<Wrapped>: Sendable where Wrapped: Sendable {
    case none
    case null
    case some(Wrapped)
}

extension GraphQLNullable: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .none
    }
}

extension GraphQLNullable: Equatable where Wrapped: Equatable {}
extension GraphQLNullable: Hashable where Wrapped: Hashable {}

extension GraphQLNullable: Decodable where Wrapped: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else {
            self = .some(try container.decode(Wrapped.self))
        }
    }
}

extension GraphQLNullable: Encodable where Wrapped: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none, .null:
            try container.encodeNil()
        case .some(let value):
            try container.encode(value)
        }
    }
}

public extension GraphQLNullable {
    var value: Wrapped? {
        guard case .some(let value) = self else { return nil }
        return value
    }
}
