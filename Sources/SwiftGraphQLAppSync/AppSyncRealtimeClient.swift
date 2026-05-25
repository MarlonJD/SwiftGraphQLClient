import Foundation
import SwiftGraphQLClient

public struct AppSyncRealtimeConfiguration: Sendable {
    public var realtimeEndpointURL: URL
    public var graphQLEndpointURL: URL
    public var authProvider: (any GraphQLAuthProvider)?
    public var keepAliveTimeout: TimeInterval?
    public var maxReconnectAttempts: Int
    public var reconnectBackoff: TimeInterval

    public init(
        realtimeEndpointURL: URL,
        graphQLEndpointURL: URL,
        authProvider: (any GraphQLAuthProvider)? = nil,
        keepAliveTimeout: TimeInterval? = nil,
        maxReconnectAttempts: Int = 0,
        reconnectBackoff: TimeInterval = 0.5
    ) {
        self.realtimeEndpointURL = realtimeEndpointURL
        self.graphQLEndpointURL = graphQLEndpointURL
        self.authProvider = authProvider
        self.keepAliveTimeout = keepAliveTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBackoff = reconnectBackoff
    }
}

public enum AppSyncRealtimeEvent<Payload: Sendable>: Sendable {
    case connectionAck
    case startAck
    case keepAlive
    case data(Payload)
    case error(GraphQLJSONValue?)
    case complete
    case ignored
}

public enum AppSyncRealtimeError: LocalizedError, Sendable {
    case serverError(GraphQLJSONValue?)
    case unsupportedMessage
    case keepAliveTimeout

    public var errorDescription: String? {
        switch self {
        case .serverError:
            return "The AppSync realtime endpoint returned an error."
        case .unsupportedMessage:
            return "The AppSync realtime endpoint returned an unsupported message."
        case .keepAliveTimeout:
            return "The AppSync realtime endpoint did not send a keepalive message before the timeout."
        }
    }
}

public protocol AppSyncWebSocketTask: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: AppSyncWebSocketTask {}

public protocol AppSyncWebSocketConnecting: Sendable {
    func appSyncWebSocketTask(with request: URLRequest) -> any AppSyncWebSocketTask
}

extension URLSession: AppSyncWebSocketConnecting {
    public func appSyncWebSocketTask(with request: URLRequest) -> any AppSyncWebSocketTask {
        webSocketTask(with: request)
    }
}

public final class AppSyncRealtimeClient: GraphQLSubscriptionTransport, @unchecked Sendable {
    private let codec: AppSyncRealtimeCodec
    private let connector: any AppSyncWebSocketConnecting

    public init(
        configuration: AppSyncRealtimeConfiguration,
        connector: any AppSyncWebSocketConnecting = URLSession.shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.codec = AppSyncRealtimeCodec(configuration: configuration, encoder: encoder, decoder: decoder)
        self.connector = connector
    }

    public func subscribe<Subscription: GraphQLSubscription>(
        _ subscription: Subscription,
        id: String = UUID().uuidString,
        onReady: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<Subscription.Data, Error> {
        AsyncThrowingStream { continuation in
            let runner = AppSyncSubscriptionRunner(
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

public struct AppSyncRealtimeCodec: Sendable {
    public var configuration: AppSyncRealtimeConfiguration

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: AppSyncRealtimeConfiguration,
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

    public func makeWebSocketRequest(headers: [String: String]) throws -> URLRequest {
        let authorization = authorizationHeaders(headers)
        let header = try base64JSONString(GraphQLJSONValue.object(authorization.mapValues(GraphQLJSONValue.string)))
        let payload = try base64JSONString(GraphQLJSONValue.object([:]))

        var components = URLComponents(url: configuration.realtimeEndpointURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "header", value: header))
        queryItems.append(URLQueryItem(name: "payload", value: payload))
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw GraphQLClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("graphql-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    public func connectionInitMessage() throws -> String {
        try encodeString(AppSyncConnectionInitMessage(type: "connection_init"))
    }

    public func startMessage<Subscription: GraphQLSubscription>(
        id: String,
        subscription: Subscription,
        headers: [String: String]
    ) throws -> String {
        let operation = GraphQLOperationPayload(
            query: Subscription.document,
            operationName: Subscription.operationName,
            variables: try GraphQLJSONEncoder.variableObject(from: subscription.variables)
        )
        let operationString = try encodeString(operation)
        let message = AppSyncStartMessage(
            id: id,
            payload: AppSyncStartPayload(
                data: operationString,
                extensions: AppSyncStartExtensions(
                    authorization: GraphQLJSONValue.object(authorizationHeaders(headers).mapValues(GraphQLJSONValue.string))
                )
            ),
            type: "start"
        )
        return try encodeString(message)
    }

    public func stopMessage(id: String) throws -> String {
        try encodeString(AppSyncStopMessage(id: id, type: "stop"))
    }

    public func decodeEvent<Payload: Decodable & Sendable>(
        data: Data,
        expectedID: String,
        as payloadType: Payload.Type = Payload.self
    ) throws -> AppSyncRealtimeEvent<Payload> {
        let envelope = try decoder.decode(AppSyncInboundMessage<Payload>.self, from: data)
        switch envelope.type {
        case "connection_ack":
            return .connectionAck
        case "start_ack":
            return envelope.id == expectedID ? .startAck : .ignored
        case "ka":
            return .keepAlive
        case "data":
            guard envelope.id == expectedID, let data = envelope.payload?.data else {
                return .ignored
            }
            return .data(data)
        case "error":
            return .error(envelope.payload?.error)
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
    ) throws -> AppSyncRealtimeEvent<Payload> {
        try decodeEvent(data: Data(text.utf8), expectedID: expectedID, as: payloadType)
    }

    private func authorizationHeaders(_ headers: [String: String]) -> [String: String] {
        var authorization = headers
        if let host = configuration.graphQLEndpointURL.host, !host.isEmpty {
            authorization["host"] = host
        }
        return authorization
    }

    private func base64JSONString<Value: Encodable>(_ value: Value) throws -> String {
        try encoder.encode(value).base64EncodedString()
    }

    private func encodeString<Value: Encodable>(_ value: Value) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GraphQLClientError.invalidResponse
        }
        return text
    }
}

private struct AppSyncConnectionInitMessage: Encodable {
    let type: String
}

private struct AppSyncStartMessage: Encodable {
    let id: String
    let payload: AppSyncStartPayload
    let type: String
}

private struct AppSyncStartPayload: Encodable {
    let data: String
    let extensions: AppSyncStartExtensions
}

private struct AppSyncStartExtensions: Encodable {
    let authorization: GraphQLJSONValue
}

private struct AppSyncStopMessage: Encodable {
    let id: String
    let type: String
}

private struct GraphQLOperationPayload: Encodable {
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

private struct AppSyncInboundMessage<Payload: Decodable>: Decodable {
    let id: String?
    let type: String
    let payload: AppSyncInboundPayload<Payload>?
}

private struct AppSyncInboundPayload<Payload: Decodable>: Decodable {
    let data: Payload?
    let error: GraphQLJSONValue?
}

private final class AppSyncSubscriptionRunner<Subscription: GraphQLSubscription>: @unchecked Sendable {
    private let codec: AppSyncRealtimeCodec
    private let connector: any AppSyncWebSocketConnecting
    private let subscription: Subscription
    private let id: String
    private let onReady: (@Sendable () -> Void)?
    private let continuation: AsyncThrowingStream<Subscription.Data, Error>.Continuation

    private let lock = NSLock()
    private var socket: (any AppSyncWebSocketTask)?
    private var task: Task<Void, Never>?

    init(
        codec: AppSyncRealtimeCodec,
        connector: any AppSyncWebSocketConnecting,
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
            if let stopMessage = try? codec.stopMessage(id: id) {
                try? await socket?.send(.string(stopMessage))
            }
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await runOnce()
                continuation.finish()
                return
            } catch {
                lockedSocket()?.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                guard shouldReconnect(after: error, attempt: attempt) else {
                    continuation.finish(throwing: error)
                    return
                }
                attempt += 1
                await sleepBeforeReconnect()
            }
        }
        continuation.finish()
    }

    private func runOnce() async throws {
        let headers = try await codec.authHeaders()
        let request = try codec.makeWebSocketRequest(headers: headers)
        let socket = connector.appSyncWebSocketTask(with: request)
        setSocket(socket)
        socket.resume()
        try await socket.send(.string(try codec.connectionInitMessage()))

        while !Task.isCancelled {
            let message = try await receive(from: socket)
            switch try decode(message) {
            case .connectionAck:
                let startMessage = try codec.startMessage(id: id, subscription: subscription, headers: headers)
                try await socket.send(.string(startMessage))
            case .startAck:
                onReady?()
            case .keepAlive, .ignored:
                continue
            case .data(let data):
                continuation.yield(data)
            case .error(let payload):
                throw AppSyncRealtimeError.serverError(payload)
            case .complete:
                return
            }
        }
    }

    private func shouldReconnect(after error: Error, attempt: Int) -> Bool {
        guard attempt < codec.configuration.maxReconnectAttempts else { return false }
        if error is CancellationError { return false }
        if let realtimeError = error as? AppSyncRealtimeError,
           case .serverError = realtimeError {
            return false
        }
        return true
    }

    private func sleepBeforeReconnect() async {
        let seconds = max(0, codec.configuration.reconnectBackoff)
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func receive(from socket: any AppSyncWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        guard let timeout = codec.configuration.keepAliveTimeout, timeout > 0 else {
            return try await socket.receive()
        }
        return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AppSyncRealtimeError.keepAliveTimeout
            }
            guard let message = try await group.next() else {
                throw AppSyncRealtimeError.unsupportedMessage
            }
            group.cancelAll()
            return message
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) throws -> AppSyncRealtimeEvent<Subscription.Data> {
        switch message {
        case .string(let text):
            return try codec.decodeEvent(text: text, expectedID: id, as: Subscription.Data.self)
        case .data(let data):
            return try codec.decodeEvent(data: data, expectedID: id, as: Subscription.Data.self)
        @unknown default:
            return .ignored
        }
    }

    private func setSocket(_ socket: any AppSyncWebSocketTask) {
        lock.lock()
        self.socket = socket
        lock.unlock()
    }

    private func lockedSocket() -> (any AppSyncWebSocketTask)? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }
}
