import Foundation
import SwiftGraphQLClient

public struct GraphQLWebSocketConfiguration: Sendable {
    public var endpointURL: URL
    public var authProvider: (any GraphQLAuthProvider)?
    public var connectionInitPayload: GraphQLJSONValue?

    public init(
        endpointURL: URL,
        authProvider: (any GraphQLAuthProvider)? = nil,
        connectionInitPayload: GraphQLJSONValue? = nil
    ) {
        self.endpointURL = endpointURL
        self.authProvider = authProvider
        self.connectionInitPayload = connectionInitPayload
    }
}

public enum GraphQLWebSocketEvent<Payload: Sendable>: Sendable {
    case connectionAck
    case ping(GraphQLJSONValue?)
    case pong(GraphQLJSONValue?)
    case next(Payload)
    case graphQLErrors([GraphQLError])
    case error(GraphQLJSONValue?)
    case complete
    case ignored
}

public enum GraphQLWebSocketError: LocalizedError, Sendable {
    case serverError(GraphQLJSONValue?)
    case unsupportedMessage

    public var errorDescription: String? {
        switch self {
        case .serverError:
            return "The GraphQL WebSocket endpoint returned an error."
        case .unsupportedMessage:
            return "The GraphQL WebSocket endpoint returned an unsupported message."
        }
    }
}

public protocol GraphQLWebSocketTask: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: GraphQLWebSocketTask {}

public protocol GraphQLWebSocketConnecting: Sendable {
    func graphQLWebSocketTask(with request: URLRequest) -> any GraphQLWebSocketTask
}

extension URLSession: GraphQLWebSocketConnecting {
    public func graphQLWebSocketTask(with request: URLRequest) -> any GraphQLWebSocketTask {
        webSocketTask(with: request)
    }
}

public final class GraphQLWebSocketClient: GraphQLSubscriptionTransport, @unchecked Sendable {
    public let configuration: GraphQLWebSocketConfiguration

    private let codec: GraphQLWebSocketCodec
    private let connector: any GraphQLWebSocketConnecting

    public init(
        configuration: GraphQLWebSocketConfiguration,
        connector: any GraphQLWebSocketConnecting = URLSession.shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.configuration = configuration
        self.codec = GraphQLWebSocketCodec(configuration: configuration, encoder: encoder, decoder: decoder)
        self.connector = connector
    }

    public func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription,
        id: String = UUID().uuidString,
        onReady: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        AsyncThrowingStream { continuation in
            let runner = GraphQLWebSocketSubscriptionRunner(
                codec: codec,
                connector: connector,
                subscription: subscription,
                id: id,
                onReady: onReady,
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in
                runner.cancel()
            }
            runner.start()
        }
    }

    public func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        subscribe(subscription, id: UUID().uuidString, onReady: nil)
    }
}

public struct GraphQLWebSocketCodec: Sendable {
    public var configuration: GraphQLWebSocketConfiguration

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: GraphQLWebSocketConfiguration,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.configuration = configuration
        self.encoder = encoder
        self.decoder = decoder
    }

    public func authHeaders() async throws -> [String: String] {
        guard let authProvider = configuration.authProvider else { return [:] }
        return try await authProvider.graphQLAuthorizationHeaders()
    }

    public func makeWebSocketRequest(headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: configuration.endpointURL)
        request.timeoutInterval = 20
        request.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    public func connectionInitMessage(payload: GraphQLJSONValue? = nil) throws -> String {
        try encodeString(GraphQLWebSocketPayloadMessage(
            type: "connection_init",
            payload: payload ?? configuration.connectionInitPayload
        ))
    }

    public func subscribeMessage<Subscription: GraphQLSubscription>(
        id: String,
        subscription: Subscription
    ) throws -> String {
        let operation = GraphQLWebSocketOperationPayload(
            query: Subscription.document,
            operationName: Subscription.operationName,
            variables: try GraphQLJSONEncoder.variableObject(from: subscription.variables)
        )
        let message = GraphQLWebSocketSubscribeMessage(
            id: id,
            payload: operation,
            type: "subscribe"
        )
        return try encodeString(message)
    }

    public func completeMessage(id: String) throws -> String {
        try encodeString(GraphQLWebSocketCompleteMessage(id: id, type: "complete"))
    }

    public func pongMessage(payload: GraphQLJSONValue? = nil) throws -> String {
        try encodeString(GraphQLWebSocketPayloadMessage(type: "pong", payload: payload))
    }

    public func decodeEvent<Payload: Decodable & Sendable>(
        data: Data,
        expectedID: String,
        as payloadType: Payload.Type = Payload.self
    ) throws -> GraphQLWebSocketEvent<Payload> {
        let envelope = try decoder.decode(GraphQLWebSocketInboundEnvelope.self, from: data)
        switch envelope.type {
        case "connection_ack":
            return .connectionAck
        case "ping":
            return .ping(envelope.payload)
        case "pong":
            return .pong(envelope.payload)
        case "next":
            guard envelope.id == expectedID, let payload = envelope.payload else {
                return .ignored
            }
            let response = try decoder.decode(GraphQLWebSocketNextPayload<Payload>.self, from: encoder.encode(payload))
            if let errors = response.errors, !errors.isEmpty {
                return .graphQLErrors(errors)
            }
            guard let data = response.data else {
                throw GraphQLClientError.missingData
            }
            return .next(data)
        case "error":
            return envelope.id == nil || envelope.id == expectedID ? .error(envelope.payload) : .ignored
        case "complete":
            return envelope.id == expectedID ? .complete : .ignored
        default:
            return .ignored
        }
    }

    public func decodeEvent<Payload: Decodable & Sendable>(
        text: String,
        expectedID: String,
        as payloadType: Payload.Type = Payload.self
    ) throws -> GraphQLWebSocketEvent<Payload> {
        try decodeEvent(data: Data(text.utf8), expectedID: expectedID, as: payloadType)
    }

    private func encodeString<Value: Encodable>(_ value: Value) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GraphQLClientError.invalidResponse
        }
        return text
    }
}

private struct GraphQLWebSocketPayloadMessage: Encodable {
    let type: String
    let payload: GraphQLJSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let payload {
            try container.encode(payload, forKey: .payload)
        }
    }
}

private struct GraphQLWebSocketSubscribeMessage: Encodable {
    let id: String
    let payload: GraphQLWebSocketOperationPayload
    let type: String
}

private struct GraphQLWebSocketOperationPayload: Encodable {
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

private struct GraphQLWebSocketCompleteMessage: Encodable {
    let id: String
    let type: String
}

private struct GraphQLWebSocketInboundEnvelope: Decodable {
    let id: String?
    let type: String
    let payload: GraphQLJSONValue?
}

private struct GraphQLWebSocketNextPayload<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GraphQLError]?
}

private final class GraphQLWebSocketSubscriptionRunner<Subscription: GraphQLSubscription>: @unchecked Sendable {
    private let codec: GraphQLWebSocketCodec
    private let connector: any GraphQLWebSocketConnecting
    private let subscription: Subscription
    private let id: String
    private let onReady: (@Sendable () -> Void)?
    private let continuation: AsyncThrowingStream<Subscription.Data, Error>.Continuation

    private let lock = NSLock()
    private var socket: (any GraphQLWebSocketTask)?
    private var task: Task<Void, Never>?

    init(
        codec: GraphQLWebSocketCodec,
        connector: any GraphQLWebSocketConnecting,
        subscription: Subscription,
        id: String,
        onReady: (@Sendable () -> Void)?,
        continuation: AsyncThrowingStream<Subscription.Data, Error>.Continuation
    ) {
        self.codec = codec
        self.connector = connector
        self.subscription = subscription
        self.id = id
        self.onReady = onReady
        self.continuation = continuation
    }

    func start() {
        task = Task {
            await run()
        }
    }

    func cancel() {
        task?.cancel()
        let socket = lockedSocket()
        Task {
            if let completeMessage = try? codec.completeMessage(id: id) {
                try? await socket?.send(.string(completeMessage))
            }
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func run() async {
        do {
            let headers = try await codec.authHeaders()
            let request = codec.makeWebSocketRequest(headers: headers)
            let socket = connector.graphQLWebSocketTask(with: request)
            setSocket(socket)
            socket.resume()
            try await socket.send(.string(try codec.connectionInitMessage()))

            var didSubscribe = false
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch try decode(message) {
                case .connectionAck:
                    guard !didSubscribe else { continue }
                    didSubscribe = true
                    let subscribeMessage = try codec.subscribeMessage(id: id, subscription: subscription)
                    try await socket.send(.string(subscribeMessage))
                    onReady?()
                case .ping(let payload):
                    try await socket.send(.string(try codec.pongMessage(payload: payload)))
                case .pong, .ignored:
                    continue
                case .next(let data):
                    continuation.yield(data)
                case .graphQLErrors(let errors):
                    continuation.finish(throwing: GraphQLClientError.graphQLErrors(errors))
                    return
                case .error(let payload):
                    continuation.finish(throwing: GraphQLWebSocketError.serverError(payload))
                    return
                case .complete:
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) throws -> GraphQLWebSocketEvent<Subscription.Data> {
        switch message {
        case .string(let text):
            return try codec.decodeEvent(text: text, expectedID: id, as: Subscription.Data.self)
        case .data(let data):
            return try codec.decodeEvent(data: data, expectedID: id, as: Subscription.Data.self)
        @unknown default:
            return .ignored
        }
    }

    private func setSocket(_ socket: any GraphQLWebSocketTask) {
        lock.lock()
        self.socket = socket
        lock.unlock()
    }

    private func lockedSocket() -> (any GraphQLWebSocketTask)? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }
}
