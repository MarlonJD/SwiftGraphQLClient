import Foundation

public enum GraphQLRequestDocumentMode: String, Sendable, Equatable {
    case fullDocument
    case operationIdentifierOnly
}

public struct GraphQLRequestContext: Sendable, Equatable {
    public var operationName: String
    public var operationIdentifier: String
    public var documentMode: GraphQLRequestDocumentMode
    public var isRetry: Bool

    public init(
        operationName: String,
        operationIdentifier: String,
        documentMode: GraphQLRequestDocumentMode,
        isRetry: Bool
    ) {
        self.operationName = operationName
        self.operationIdentifier = operationIdentifier
        self.documentMode = documentMode
        self.isRetry = isRetry
    }
}

public protocol GraphQLRequestInterceptor: Sendable {
    func intercept(_ request: URLRequest, context: GraphQLRequestContext) async throws -> URLRequest
}

public protocol GraphQLResponseInterceptor: Sendable {
    func intercept(
        data: Data,
        response: HTTPURLResponse,
        context: GraphQLRequestContext
    ) async throws -> (Data, HTTPURLResponse)
}

public struct GraphQLHeaderInterceptor: GraphQLRequestInterceptor {
    public var headers: [String: String]

    public init(headers: [String: String]) {
        self.headers = headers
    }

    public func intercept(_ request: URLRequest, context: GraphQLRequestContext) async throws -> URLRequest {
        var request = request
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
