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
    public var persistedQueries: GraphQLPersistedQueryConfiguration
    public var requestInterceptors: [any GraphQLRequestInterceptor]
    public var responseInterceptors: [any GraphQLResponseInterceptor]

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
        cacheRefreshTaskPriority: TaskPriority = .utility,
        persistedQueries: GraphQLPersistedQueryConfiguration = .disabled,
        requestInterceptors: [any GraphQLRequestInterceptor] = [],
        responseInterceptors: [any GraphQLResponseInterceptor] = []
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
        self.persistedQueries = persistedQueries
        self.requestInterceptors = requestInterceptors
        self.responseInterceptors = responseInterceptors
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
        let execution = try await execute(mutation, didRefresh: false, didPersistedQueryRetry: false)
        let data = try materialize(execution.result)
        if execution.result.errors.isEmpty, let rawData = execution.rawData {
            try await configuration.responseCache?.write(mutation, data: rawData)
        }
        return data
    }

    public func send<Operation: GraphQLOperation>(_ operation: Operation) async throws -> GraphQLResult<Operation.Data> {
        try await execute(operation, didRefresh: false, didPersistedQueryRetry: false).result
    }

    public func fetchIncremental<Query: GraphQLQuery>(
        _ query: Query
    ) -> AsyncThrowingStream<GraphQLIncrementalResult<Query.Data>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let results = try await executeIncremental(query, mergesPatches: false, writesToCache: false)
                    for result in results {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func fetchIncrementalMerged<Query: GraphQLQuery>(
        _ query: Query,
        writesToCache: Bool = true
    ) -> AsyncThrowingStream<GraphQLIncrementalResult<Query.Data>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let results = try await executeIncremental(query, mergesPatches: true, writesToCache: writesToCache)
                    for result in results {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
        let execution = try await execute(query, didRefresh: false, didPersistedQueryRetry: false)
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
        didRefresh: Bool,
        didPersistedQueryRetry: Bool
    ) async throws -> GraphQLExecutionResult<Operation.Data> {
        let documentMode = requestDocumentMode(didPersistedQueryRetry: didPersistedQueryRetry)
        let context = GraphQLRequestContext(
            operationName: Operation.operationName,
            operationIdentifier: Operation.operationIdentifier,
            documentMode: documentMode,
            isRetry: didRefresh || didPersistedQueryRetry
        )
        let request = try await makeRequest(
            for: operation,
            documentMode: documentMode,
            useGET: configuration.persistedQueries.useGETForRetry && didPersistedQueryRetry
        )
        let (rawData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphQLClientError.invalidResponse
        }
        var data = rawData
        var interceptedResponse = httpResponse
        for interceptor in configuration.responseInterceptors {
            (data, interceptedResponse) = try await interceptor.intercept(
                data: data,
                response: interceptedResponse,
                context: context
            )
        }

        if interceptedResponse.statusCode == 401, !didRefresh, try await refreshSession() {
            return try await execute(operation, didRefresh: true, didPersistedQueryRetry: didPersistedQueryRetry)
        }

        guard (200...299).contains(interceptedResponse.statusCode) else {
            throw GraphQLClientError.httpStatus(statusCode: interceptedResponse.statusCode, body: data.isEmpty ? nil : data)
        }
        guard !data.isEmpty else {
            throw GraphQLClientError.invalidResponse
        }

        let envelope = try decoder.decode(GraphQLRawResponseEnvelope.self, from: data)
        let typedData = try envelope.data.map {
            try GraphQLResponseMaterializer.decode(Operation.Data.self, from: $0, decoder: decoder)
        }
        let result = GraphQLResult(data: typedData, errors: envelope.errors ?? [])
        if !didPersistedQueryRetry, shouldRetryPersistedQuery(result.errors) {
            return try await execute(operation, didRefresh: didRefresh, didPersistedQueryRetry: true)
        }
        if !didRefresh, result.errors.contains(where: { $0.isUnauthorized }), try await refreshSession() {
            return try await execute(operation, didRefresh: true, didPersistedQueryRetry: didPersistedQueryRetry)
        }
        return GraphQLExecutionResult(result: result, rawData: envelope.data)
    }

    private func executeIncremental<Operation: GraphQLOperation>(
        _ operation: Operation,
        mergesPatches: Bool,
        writesToCache: Bool
    ) async throws -> [GraphQLIncrementalResult<Operation.Data>] {
        let rawResults = try await executeIncrementalRaw(operation)
        guard mergesPatches else {
            return try rawResults.map { rawResult in
                let typedData = try rawResult.data.map {
                    try GraphQLResponseMaterializer.decode(Operation.Data.self, from: $0, decoder: decoder)
                }
                return GraphQLIncrementalResult(
                    data: typedData,
                    errors: rawResult.errors,
                    patches: rawResult.patches,
                    hasNext: rawResult.hasNext
                )
            }
        }

        var currentData: GraphQLJSONValue?
        var mergedResults: [GraphQLIncrementalResult<Operation.Data>] = []
        for rawResult in rawResults {
            if let data = rawResult.data {
                currentData = data
            }
            if !rawResult.patches.isEmpty {
                currentData = try GraphQLIncrementalPatchMerger.applying(
                    patches: rawResult.patches,
                    to: currentData
                )
            }
            let typedData = try currentData.map {
                try GraphQLResponseMaterializer.decode(Operation.Data.self, from: $0, decoder: decoder)
            }
            if writesToCache,
               rawResult.hasNext == false,
               rawResult.errors.isEmpty,
               let currentData {
                try await configuration.responseCache?.write(operation, data: currentData)
            }
            mergedResults.append(GraphQLIncrementalResult(
                data: typedData,
                errors: rawResult.errors,
                patches: rawResult.patches,
                hasNext: rawResult.hasNext
            ))
        }
        return mergedResults
    }

    private func executeIncrementalRaw<Operation: GraphQLOperation>(
        _ operation: Operation
    ) async throws -> [GraphQLRawIncrementalResult] {
        let documentMode = requestDocumentMode(didPersistedQueryRetry: false)
        let context = GraphQLRequestContext(
            operationName: Operation.operationName,
            operationIdentifier: Operation.operationIdentifier,
            documentMode: documentMode,
            isRetry: false
        )
        let request = try await makeRequest(for: operation, documentMode: documentMode, useGET: false)
        let (rawData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphQLClientError.invalidResponse
        }
        var data = rawData
        var interceptedResponse = httpResponse
        for interceptor in configuration.responseInterceptors {
            (data, interceptedResponse) = try await interceptor.intercept(
                data: data,
                response: interceptedResponse,
                context: context
            )
        }
        guard (200...299).contains(interceptedResponse.statusCode) else {
            throw GraphQLClientError.httpStatus(statusCode: interceptedResponse.statusCode, body: data.isEmpty ? nil : data)
        }
        let parts = GraphQLHTTPMultipartResponseParser.responseParts(
            data: data,
            contentType: interceptedResponse.value(forHTTPHeaderField: "Content-Type")
        )
        return try parts.map { part in
            let envelope = try decoder.decode(GraphQLRawResponseEnvelope.self, from: part)
            return GraphQLRawIncrementalResult(
                data: envelope.data,
                errors: envelope.errors ?? [],
                patches: envelope.incremental?.map(\.patch) ?? [],
                hasNext: envelope.hasNext
            )
        }
    }

    private func makeRequest<Operation: GraphQLOperation>(
        for operation: Operation,
        documentMode: GraphQLRequestDocumentMode,
        useGET: Bool
    ) async throws -> URLRequest {
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = useGET ? "GET" : "POST"
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
           documentMode == .fullDocument,
           let multipartRequestBody = try multipartRequestEncoder.multipartRequestBody(for: operation) {
            request.setValue(multipartRequestBody.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = multipartRequestBody.body
            return try await intercept(request, for: operation, documentMode: documentMode, isRetry: false)
        }

        let body = GraphQLRequestBody(
            query: documentMode == .fullDocument ? Operation.document : nil,
            operationName: Operation.operationName,
            variables: try GraphQLJSONEncoder.variableObject(from: operation.variables),
            extensions: persistedQueryExtensions(for: Operation.self)
        )
        if useGET {
            request.url = try getURL(for: request.url, body: body)
        } else {
            request.httpBody = try encoder.encode(body)
        }
        return try await intercept(request, for: operation, documentMode: documentMode, isRetry: useGET)
    }

    private func refreshSession() async throws -> Bool {
        guard let sessionRefresher = configuration.sessionRefresher else { return false }
        return try await refreshCoordinator.refresh {
            try await sessionRefresher.refreshSession()
        }
    }

    private func requestDocumentMode(didPersistedQueryRetry: Bool) -> GraphQLRequestDocumentMode {
        switch configuration.persistedQueries.mode {
        case .disabled:
            return .fullDocument
        case .automaticPersistedQueries, .persistedQueries:
            return didPersistedQueryRetry ? .fullDocument : .operationIdentifierOnly
        }
    }

    private func persistedQueryExtensions<Operation: GraphQLOperation>(
        for operation: Operation.Type
    ) -> GraphQLJSONValue? {
        guard configuration.persistedQueries.mode != .disabled else { return nil }
        return .object([
            "persistedQuery": .object([
                "version": .int(1),
                "sha256Hash": .string(Operation.operationIdentifier)
            ])
        ])
    }

    private func shouldRetryPersistedQuery(_ errors: [GraphQLError]) -> Bool {
        guard errors.contains(where: \.isPersistedQueryNotFound) else { return false }
        switch configuration.persistedQueries.mode {
        case .disabled:
            return false
        case .automaticPersistedQueries:
            return true
        case .persistedQueries:
            return configuration.persistedQueries.sendsDocumentOnFallback
        }
    }

    private func getURL(for url: URL?, body: GraphQLRequestBody) throws -> URL {
        guard let url else { throw GraphQLClientError.invalidResponse }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if let query = body.query {
            items.append(URLQueryItem(name: "query", value: query))
        }
        items.append(URLQueryItem(name: "operationName", value: body.operationName))
        if let variables = body.variables {
            let data = try encoder.encode(variables)
            items.append(URLQueryItem(name: "variables", value: String(decoding: data, as: UTF8.self)))
        }
        if let extensions = body.extensions {
            let data = try encoder.encode(extensions)
            items.append(URLQueryItem(name: "extensions", value: String(decoding: data, as: UTF8.self)))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { throw GraphQLClientError.invalidResponse }
        return finalURL
    }

    private func intercept<Operation: GraphQLOperation>(
        _ request: URLRequest,
        for operation: Operation,
        documentMode: GraphQLRequestDocumentMode,
        isRetry: Bool
    ) async throws -> URLRequest {
        var request = request
        let context = GraphQLRequestContext(
            operationName: Operation.operationName,
            operationIdentifier: Operation.operationIdentifier,
            documentMode: documentMode,
            isRetry: isRetry
        )
        for interceptor in configuration.requestInterceptors {
            request = try await interceptor.intercept(request, context: context)
        }
        return request
    }
}

private struct GraphQLExecutionResult<Data: Sendable>: Sendable {
    let result: GraphQLResult<Data>
    let rawData: GraphQLJSONValue?
}

private struct GraphQLRawIncrementalResult: Sendable {
    let data: GraphQLJSONValue?
    let errors: [GraphQLError]
    let patches: [GraphQLIncrementalPatch]
    let hasNext: Bool?
}

private struct GraphQLRequestBody: Encodable {
    let query: String?
    let operationName: String
    let variables: GraphQLJSONValue?
    let extensions: GraphQLJSONValue?

    enum CodingKeys: String, CodingKey {
        case query
        case operationName
        case variables
        case extensions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let query {
            try container.encode(query, forKey: .query)
        }
        try container.encode(operationName, forKey: .operationName)
        if let variables {
            try container.encode(variables, forKey: .variables)
        }
        if let extensions {
            try container.encode(extensions, forKey: .extensions)
        }
    }
}
