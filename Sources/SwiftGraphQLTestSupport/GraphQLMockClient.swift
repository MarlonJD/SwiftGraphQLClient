import Foundation
import SwiftGraphQLClient

public actor GraphQLMockClient {
    private var operationResults: [String: Any] = [:]
    private var operationErrors: [String: Error] = [:]
    private var subscriptionResults: [String: [Any]] = [:]

    public private(set) var executedOperationNames: [String] = []

    public init() {}

    public func enqueue<Operation: GraphQLOperation>(
        _ operation: Operation.Type,
        data: Operation.Data
    ) {
        operationResults[Operation.operationName] = data
    }

    public func enqueue<Operation: GraphQLOperation>(
        _ operation: Operation.Type,
        error: Error
    ) {
        operationErrors[Operation.operationName] = error
    }

    public func enqueueSubscription<Subscription: GraphQLSubscription>(
        _ subscription: Subscription.Type,
        data: [Subscription.Data]
    ) {
        subscriptionResults[Subscription.operationName] = data
    }

    public func fetch<Query: GraphQLQuery>(
        _ query: Query,
        cachePolicy: GraphQLCachePolicy = .networkOnly
    ) async throws -> Query.Data {
        try result(for: Query.self)
    }

    public func perform<Mutation: GraphQLMutation>(
        _ mutation: Mutation
    ) async throws -> Mutation.Data {
        try result(for: Mutation.self)
    }

    public nonisolated func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let values = try await subscriptionValues(for: Subscription.self)
                    for value in values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func result<Operation: GraphQLOperation>(
        for operation: Operation.Type
    ) throws -> Operation.Data {
        executedOperationNames.append(Operation.operationName)
        if let error = operationErrors[Operation.operationName] {
            throw error
        }
        guard let data = operationResults[Operation.operationName] as? Operation.Data else {
            throw GraphQLClientError.missingData
        }
        return data
    }

    private func subscriptionValues<Subscription: GraphQLSubscription>(
        for subscription: Subscription.Type
    ) throws -> [Subscription.Data] {
        executedOperationNames.append(Subscription.operationName)
        if let error = operationErrors[Subscription.operationName] {
            throw error
        }
        guard let data = subscriptionResults[Subscription.operationName] as? [Subscription.Data] else {
            throw GraphQLClientError.missingData
        }
        return data
    }
}

public struct GraphQLTestDataBuilder<Data: Sendable>: Sendable {
    private let buildData: @Sendable () throws -> Data

    public init(_ buildData: @escaping @Sendable () throws -> Data) {
        self.buildData = buildData
    }

    public func build() throws -> Data {
        try buildData()
    }
}
