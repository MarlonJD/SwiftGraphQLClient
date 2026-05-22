import Foundation

public protocol GraphQLOperation: Sendable {
    associatedtype Variables: Encodable & Sendable = EmptyGraphQLVariables
    associatedtype Data: Decodable & Sendable
    associatedtype ResponseFormat = SingleResponseFormat

    static var operationName: String { get }
    static var document: String { get }
    static var selections: [GraphQLSelection] { get }
    var variables: Variables { get }
}

public protocol GraphQLQuery: GraphQLOperation {}
public protocol GraphQLMutation: GraphQLOperation {}
public protocol GraphQLSubscription: GraphQLOperation {}

public struct EmptyGraphQLVariables: Encodable, Sendable, Equatable {
    public init() {}
}

public extension GraphQLOperation where Variables == EmptyGraphQLVariables {
    var variables: EmptyGraphQLVariables { EmptyGraphQLVariables() }
}

public enum GraphQLCachePolicy: String, Sendable, Codable, CaseIterable {
    case networkOnly
    case cacheFirst
    case cacheOnly
    case cacheAndNetwork
    case noCache
}

public enum CachePolicy {
    public enum Query {
        public typealias SingleResponse = GraphQLCachePolicy
    }
}

public enum SingleResponseFormat: Sendable {}

public indirect enum GraphQLSelection: Sendable, Equatable, Codable {
    case field(name: String, responseName: String, selections: [GraphQLSelection])
    case fragmentSpread(String)
    case inlineFragment(typeName: String?, selections: [GraphQLSelection])
}

public extension GraphQLOperation {
    static var selections: [GraphQLSelection] { [] }
}
