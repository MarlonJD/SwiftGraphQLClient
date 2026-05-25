import Foundation

public protocol GraphQLURLSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GraphQLURLSession {}

public struct GraphQLClientConfiguration: Sendable {
    public var endpointURL: URL
    public var authProvider: (any GraphQLAuthProvider)?
    public var additionalHeaders: [String: String]
    public var deviceFingerprint: String?
    public var deviceFingerprintHeaderName: String
    public var sessionRefresher: (any GraphQLSessionRefresher)?
    public var subscriptionTransport: (any GraphQLSubscriptionTransport)?
    public var multipartRequestEncoder: (any GraphQLMultipartRequestEncoding)?
    public var responseCache: (any GraphQLOperationCache)?
    public var cacheRefreshTaskPriority: TaskPriority

    public init(
        endpointURL: URL,
        authProvider: (any GraphQLAuthProvider)? = nil,
        additionalHeaders: [String: String] = [:],
        deviceFingerprint: String? = nil,
        deviceFingerprintHeaderName: String = "X-Device-Fingerprint",
        sessionRefresher: (any GraphQLSessionRefresher)? = nil,
        subscriptionTransport: (any GraphQLSubscriptionTransport)? = nil,
        multipartRequestEncoder: (any GraphQLMultipartRequestEncoding)? = nil,
        responseCache: (any GraphQLOperationCache)? = nil,
        cacheRefreshTaskPriority: TaskPriority = .utility
    ) {
        self.endpointURL = endpointURL
        self.authProvider = authProvider
        self.additionalHeaders = additionalHeaders
        self.deviceFingerprint = deviceFingerprint
        self.deviceFingerprintHeaderName = deviceFingerprintHeaderName
        self.sessionRefresher = sessionRefresher
        self.subscriptionTransport = subscriptionTransport
        self.multipartRequestEncoder = multipartRequestEncoder
        self.responseCache = responseCache
        self.cacheRefreshTaskPriority = cacheRefreshTaskPriority
    }
}

public final class GraphQLClient: @unchecked Sendable {
    private let configuration: GraphQLClientConfiguration
    private let session: any GraphQLURLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let refreshCoordinator = GraphQLRefreshCoordinator()

    public init(
        configuration: GraphQLClientConfiguration,
        session: any GraphQLURLSession = URLSession.shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.configuration = configuration
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    public func fetch<Query: GraphQLQuery>(
        _ query: Query,
        cachePolicy: GraphQLCachePolicy = .networkOnly
    ) async throws -> Query.Data {
        switch cachePolicy {
        case .networkOnly:
            return try await fetchFromNetwork(query, writesToCache: true)
        case .noCache:
            return try await fetchFromNetwork(query, writesToCache: false)
        case .cacheOnly:
            return try await fetchFromCache(query)
        case .cacheFirst:
            if let cached = try await cachedData(query) {
                return cached
            }
            return try await fetchFromNetwork(query, writesToCache: true)
        case .cacheAndNetwork:
            if let cached = try await cachedData(query) {
                Task(priority: configuration.cacheRefreshTaskPriority) { [self] in
                    try? await fetchFromNetwork(query, writesToCache: true)
                }
                return cached
            }
            return try await fetchFromNetwork(query, writesToCache: true)
        }
    }

    public func perform<Mutation: GraphQLMutation>(_ mutation: Mutation) async throws -> Mutation.Data {
        let execution = try await execute(mutation, didRefresh: false)
        let data = try materialize(execution.result)
        if execution.result.errors.isEmpty, let rawData = execution.rawData {
            try await configuration.responseCache?.write(mutation, data: rawData)
        }
        return data
    }

    public func send<Operation: GraphQLOperation>(_ operation: Operation) async throws -> GraphQLResult<Operation.Data> {
        try await execute(operation, didRefresh: false).result
    }

    public func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        guard let subscriptionTransport = configuration.subscriptionTransport else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: GraphQLClientError.unsupportedSubscriptions)
            }
        }
        return subscriptionTransport.subscribe(subscription)
    }

    private func materialize<Data>(_ result: GraphQLResult<Data>) throws -> Data {
        if !result.errors.isEmpty {
            throw GraphQLClientError.graphQLErrors(result.errors)
        }
        guard let data = result.data else {
            throw GraphQLClientError.missingData
        }
        return data
    }

    private func fetchFromNetwork<Query: GraphQLQuery>(_ query: Query, writesToCache: Bool) async throws -> Query.Data {
        let execution = try await execute(query, didRefresh: false)
        let data = try materialize(execution.result)
        if writesToCache, execution.result.errors.isEmpty, let rawData = execution.rawData {
            try await configuration.responseCache?.write(query, data: rawData)
        }
        return data
    }

    private func fetchFromCache<Query: GraphQLQuery>(_ query: Query) async throws -> Query.Data {
        guard let cached = try await cachedResponse(query) else {
            throw GraphQLClientError.cacheMiss
        }
        if cached.isPartial {
            throw GraphQLClientError.partialCacheHit(missingFields: cached.missingFields)
        }
        guard let data = cached.data else {
            throw GraphQLClientError.cacheMiss
        }
        return try GraphQLResponseMaterializer.decode(Query.Data.self, from: data, decoder: decoder)
    }

    private func cachedData<Query: GraphQLQuery>(_ query: Query) async throws -> Query.Data? {
        guard let cached = try await cachedResponse(query),
              !cached.isPartial,
              let data = cached.data else {
            return nil
        }
        return try GraphQLResponseMaterializer.decode(Query.Data.self, from: data, decoder: decoder)
    }

    private func cachedResponse<Operation: GraphQLOperation>(_ operation: Operation) async throws -> GraphQLCachedResponse? {
        guard let cache = configuration.responseCache else { return nil }
        let cached = try await cache.read(operation)
        guard cached.data != nil || cached.isPartial else { return nil }
        return cached
    }

    private func execute<Operation: GraphQLOperation>(
        _ operation: Operation,
        didRefresh: Bool
    ) async throws -> GraphQLExecutionResult<Operation.Data> {
        let request = try await makeRequest(for: operation)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphQLClientError.invalidResponse
        }

        if httpResponse.statusCode == 401, !didRefresh, try await refreshSession() {
            return try await execute(operation, didRefresh: true)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GraphQLClientError.httpStatus(statusCode: httpResponse.statusCode, body: data.isEmpty ? nil : data)
        }
        guard !data.isEmpty else {
            throw GraphQLClientError.invalidResponse
        }

        let envelope = try decoder.decode(GraphQLRawResponseEnvelope.self, from: data)
        let typedData = try envelope.data.map {
            try GraphQLResponseMaterializer.decode(Operation.Data.self, from: $0, decoder: decoder)
        }
        let result = GraphQLResult(data: typedData, errors: envelope.errors ?? [])
        if !didRefresh, result.errors.contains(where: { $0.isUnauthorized }), try await refreshSession() {
            return try await execute(operation, didRefresh: true)
        }
        return GraphQLExecutionResult(result: result, rawData: envelope.data)
    }

    private func makeRequest<Operation: GraphQLOperation>(for operation: Operation) async throws -> URLRequest {
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/graphql-response+json, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (name, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let deviceFingerprint = configuration.deviceFingerprint, !deviceFingerprint.isEmpty {
            request.setValue(deviceFingerprint, forHTTPHeaderField: configuration.deviceFingerprintHeaderName)
        }
        if let authProvider = configuration.authProvider {
            for (name, value) in try await authProvider.graphQLAuthorizationHeaders() {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        if let multipartRequestEncoder = configuration.multipartRequestEncoder,
           let multipartRequestBody = try multipartRequestEncoder.multipartRequestBody(for: operation) {
            request.setValue(multipartRequestBody.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = multipartRequestBody.body
            return request
        }

        let body = GraphQLRequestBody(
            query: Operation.document,
            operationName: Operation.operationName,
            variables: try GraphQLJSONEncoder.variableObject(from: operation.variables)
        )
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func refreshSession() async throws -> Bool {
        guard let sessionRefresher = configuration.sessionRefresher else { return false }
        return try await refreshCoordinator.refresh {
            try await sessionRefresher.refreshSession()
        }
    }
}

private struct GraphQLExecutionResult<Data: Sendable>: Sendable {
    let result: GraphQLResult<Data>
    let rawData: GraphQLJSONValue?
}

private struct GraphQLRequestBody: Encodable {
    let query: String
    let operationName: String
    let variables: GraphQLJSONValue?

    enum CodingKeys: String, CodingKey {
        case query
        case operationName
        case variables
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encode(operationName, forKey: .operationName)
        if let variables {
            try container.encode(variables, forKey: .variables)
        }
    }
}

private struct GraphQLRawResponseEnvelope: Decodable {
    let data: GraphQLJSONValue?
    let errors: [GraphQLError]?
}
