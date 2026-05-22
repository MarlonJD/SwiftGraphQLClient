import Foundation

public struct GraphQLResult<Data: Sendable>: Sendable {
    public let data: Data?
    public let errors: [GraphQLError]

    public init(data: Data?, errors: [GraphQLError] = []) {
        self.data = data
        self.errors = errors
    }
}

public struct GraphQLError: Decodable, Equatable, LocalizedError, Sendable {
    public struct Location: Decodable, Equatable, Sendable {
        public let line: Int
        public let column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    public enum PathComponent: Decodable, Equatable, Sendable {
        case string(String)
        case int(Int)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported GraphQL error path component.")
            }
        }
    }

    public let message: String
    public let locations: [Location]?
    public let path: [PathComponent]?
    public let extensions: GraphQLJSONValue?

    public init(
        message: String,
        locations: [Location]? = nil,
        path: [PathComponent]? = nil,
        extensions: GraphQLJSONValue? = nil
    ) {
        self.message = message
        self.locations = locations
        self.path = path
        self.extensions = extensions
    }

    public var errorDescription: String? {
        message
    }

    public var code: String? {
        guard let object = extensions?.objectValue else { return nil }
        return object["code"]?.stringValue ?? object["errorType"]?.stringValue
    }

    public var statusCode: Int? {
        guard let object = extensions?.objectValue else { return nil }
        return object["status"]?.intValue ?? object["statusCode"]?.intValue
    }

    public var isUnauthorized: Bool {
        if statusCode == 401 {
            return true
        }
        guard let code = code?.uppercased() else {
            return false
        }
        return [
            "UNAUTHENTICATED",
            "UNAUTHORIZED",
            "UNAUTHORIZEDEXCEPTION",
            "TOKEN_EXPIRED",
            "JWT_EXPIRED"
        ].contains(code)
    }
}

public enum GraphQLClientError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(statusCode: Int, body: Data?)
    case graphQLErrors([GraphQLError])
    case missingData
    case unsupportedCachePolicy(GraphQLCachePolicy)
    case unsupportedSubscriptions

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The GraphQL response is invalid."
        case .httpStatus(let statusCode, _):
            return "The GraphQL endpoint returned HTTP \(statusCode)."
        case .graphQLErrors(let errors):
            return errors.first?.message ?? "The GraphQL endpoint returned errors."
        case .missingData:
            return "The GraphQL response did not contain data."
        case .unsupportedCachePolicy(let policy):
            return "The cache policy \(policy.rawValue) is not supported by this client."
        case .unsupportedSubscriptions:
            return "No GraphQL subscription transport is configured."
        }
    }

    public var isUnauthorized: Bool {
        switch self {
        case .httpStatus(let statusCode, _):
            return statusCode == 401
        case .graphQLErrors(let errors):
            return errors.contains { $0.isUnauthorized }
        case .invalidResponse, .missingData, .unsupportedCachePolicy, .unsupportedSubscriptions:
            return false
        }
    }
}
