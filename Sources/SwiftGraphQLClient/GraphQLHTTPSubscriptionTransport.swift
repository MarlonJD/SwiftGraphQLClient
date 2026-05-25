import Foundation

public final class GraphQLHTTPSubscriptionTransport: GraphQLSubscriptionTransport, @unchecked Sendable {
    private let endpointURL: URL
    private let session: any GraphQLURLSession
    private let authProvider: (any GraphQLAuthProvider)?
    private let additionalHeaders: [String: String]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        endpointURL: URL,
        session: any GraphQLURLSession = URLSession.shared,
        authProvider: (any GraphQLAuthProvider)? = nil,
        additionalHeaders: [String: String] = [:],
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.endpointURL = endpointURL
        self.session = session
        self.authProvider = authProvider
        self.additionalHeaders = additionalHeaders
        self.encoder = encoder
        self.decoder = decoder
    }

    public func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await makeRequest(for: subscription)
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw GraphQLClientError.invalidResponse
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        throw GraphQLClientError.httpStatus(statusCode: httpResponse.statusCode, body: data.isEmpty ? nil : data)
                    }
                    let parts = GraphQLHTTPMultipartResponseParser.responseParts(
                        data: data,
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
                    )
                    for part in parts {
                        try Task.checkCancellation()
                        let envelope = try decoder.decode(GraphQLRawResponseEnvelope.self, from: part)
                        if let errors = envelope.errors, !errors.isEmpty {
                            throw GraphQLClientError.graphQLErrors(errors)
                        }
                        if let data = envelope.data {
                            let typed = try GraphQLResponseMaterializer.decode(
                                Subscription.Data.self,
                                from: data,
                                decoder: decoder
                            )
                            continuation.yield(typed)
                        }
                        if envelope.hasNext == false {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest<Subscription: GraphQLSubscription>(
        for subscription: Subscription
    ) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/graphql-response+json, multipart/mixed, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let authProvider {
            for (name, value) in try await authProvider.graphQLAuthorizationHeaders() {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        request.httpBody = try encoder.encode(GraphQLHTTPSubscriptionRequestBody(
            query: Subscription.document,
            operationName: Subscription.operationName,
            variables: try GraphQLJSONEncoder.variableObject(from: subscription.variables)
        ))
        return request
    }
}

private struct GraphQLHTTPSubscriptionRequestBody: Encodable {
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
