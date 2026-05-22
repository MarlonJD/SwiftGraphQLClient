import Foundation

public struct GraphQLMultipartRequestBody: Sendable, Equatable {
    public var body: Data
    public var contentType: String

    public init(body: Data, contentType: String) {
        self.body = body
        self.contentType = contentType
    }
}

public protocol GraphQLMultipartRequestEncoding: Sendable {
    func multipartRequestBody<Operation: GraphQLOperation>(
        for operation: Operation
    ) throws -> GraphQLMultipartRequestBody?
}
