import Foundation
import SwiftGraphQLClient
import SwiftGraphQLWebSocket
import XCTest

final class GraphQLWebSocketClientTests: XCTestCase {
    func testClientStreamsGeneratedSubscriptionDataAndRespondsToPing() async throws {
        let socket = MockGraphQLWebSocketTask(messages: [
            .string(#"{"type":"connection_ack"}"#),
            .string(#"{"type":"ping","payload":{"t":"1"}}"#),
            .string(#"{"type":"next","id":"sub-1","payload":{"data":{"messageCreated":{"id":"message-1","requestId":"request-1"}}}}"#),
            .string(#"{"type":"complete","id":"sub-1"}"#)
        ])
        let connector = MockGraphQLWebSocketConnector(socket: socket)
        let ready = expectation(description: "subscription ready")
        let client = GraphQLWebSocketClient(
            configuration: GraphQLWebSocketConfiguration(
                endpointURL: URL(string: "wss://api.example.com/graphql")!,
                authProvider: BearerTokenAuthProvider(token: "token-1"),
                connectionInitPayload: .object(["client": .string("kindred")])
            ),
            connector: connector
        )

        let stream = client.subscribe(
            MessageCreatedSubscription(requestId: "request-1"),
            id: "sub-1",
            onReady: { ready.fulfill() }
        )
        var iterator = stream.makeAsyncIterator()
        let data = try await iterator.next()

        XCTAssertEqual(data?.messageCreated.id, "message-1")
        XCTAssertEqual(data?.messageCreated.requestId, "request-1")
        let completed = try await iterator.next()
        XCTAssertNil(completed)
        await fulfillment(of: [ready], timeout: 1)

        let sent = await socket.sentStrings
        let messageTypes = try sent.map(messageType)
        XCTAssertEqual(Array(messageTypes.prefix(3)), ["connection_init", "subscribe", "pong"])

        let pong = try XCTUnwrap(sent.first { try messageType($0) == "pong" })
        let pongJSON = try JSONObject(from: pong)
        let pongPayload = try XCTUnwrap(pongJSON["payload"] as? [String: Any])
        XCTAssertEqual(pongPayload["t"] as? String, "1")

        XCTAssertEqual(connector.requests.count, 1)
        let request = try XCTUnwrap(connector.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "graphql-transport-ws")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")

        let didResume = await socket.didResume
        XCTAssertTrue(didResume)
    }

    func testCodecBuildsProtocolMessages() throws {
        let codec = makeCodec(connectionInitPayload: .object(["source": .string("test")]))

        let connectionInit = try JSONObject(from: codec.connectionInitMessage())
        XCTAssertEqual(connectionInit["type"] as? String, "connection_init")
        let initPayload = try XCTUnwrap(connectionInit["payload"] as? [String: Any])
        XCTAssertEqual(initPayload["source"] as? String, "test")

        let subscribe = try JSONObject(from: codec.subscribeMessage(
            id: "sub-1",
            subscription: MessageCreatedSubscription(requestId: "request-1")
        ))
        XCTAssertEqual(subscribe["type"] as? String, "subscribe")
        XCTAssertEqual(subscribe["id"] as? String, "sub-1")

        let payload = try XCTUnwrap(subscribe["payload"] as? [String: Any])
        XCTAssertEqual(payload["operationName"] as? String, "MessageCreated")
        XCTAssertEqual(payload["query"] as? String, MessageCreatedSubscription.document)
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["requestId"] as? String, "request-1")

        let complete = try JSONObject(from: codec.completeMessage(id: "sub-1"))
        XCTAssertEqual(complete["type"] as? String, "complete")
        XCTAssertEqual(complete["id"] as? String, "sub-1")
    }

    func testDecodeEvents() throws {
        let codec = makeCodec()

        if case .connectionAck = try codec.decodeEvent(text: #"{"type":"connection_ack"}"#, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        } else {
            XCTFail("Expected connection ack.")
        }

        if case .ping(let payload) = try codec.decodeEvent(text: #"{"type":"ping","payload":{"t":"1"}}"#, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
            XCTAssertEqual(payload, .object(["t": .string("1")]))
        } else {
            XCTFail("Expected ping.")
        }

        let dataMessage = """
        {"type":"next","id":"sub-1","payload":{"data":{"messageCreated":{"id":"message-1","requestId":"request-1"}}}}
        """
        switch try codec.decodeEvent(text: dataMessage, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        case .next(let data):
            XCTAssertEqual(data.messageCreated.id, "message-1")
            XCTAssertEqual(data.messageCreated.requestId, "request-1")
        default:
            XCTFail("Expected next event.")
        }

        if case .ignored = try codec.decodeEvent(text: dataMessage, expectedID: "other", as: MessageCreatedSubscription.Data.self) {
        } else {
            XCTFail("Expected ignored event for a different subscription id.")
        }

        let errorMessage = """
        {"type":"next","id":"sub-1","payload":{"errors":[{"message":"Unauthorized","extensions":{"code":"UNAUTHENTICATED"}}]}}
        """
        switch try codec.decodeEvent(text: errorMessage, expectedID: "sub-1", as: MessageCreatedSubscription.Data.self) {
        case .graphQLErrors(let errors):
            XCTAssertEqual(errors.first?.message, "Unauthorized")
            XCTAssertTrue(errors.first?.isUnauthorized ?? false)
        default:
            XCTFail("Expected GraphQL errors.")
        }
    }

    private func makeCodec(connectionInitPayload: GraphQLJSONValue? = nil) -> GraphQLWebSocketCodec {
        GraphQLWebSocketCodec(configuration: GraphQLWebSocketConfiguration(
            endpointURL: URL(string: "wss://api.example.com/graphql")!,
            connectionInitPayload: connectionInitPayload
        ))
    }

    private func JSONObject(from text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func messageType(_ text: String) throws -> String {
        let json = try JSONObject(from: text)
        return try XCTUnwrap(json["type"] as? String)
    }
}

private struct MessageCreatedSubscription: GraphQLSubscription {
    struct Variables: Encodable, Sendable {
        let requestId: GraphQLID
    }

    struct Data: Codable, Sendable, Equatable {
        struct MessageCreated: Codable, Sendable, Equatable {
            let id: GraphQLID
            let requestId: GraphQLID
        }

        let messageCreated: MessageCreated
    }

    static let operationName = "MessageCreated"
    static let document = "subscription MessageCreated($requestId: ID!) { messageCreated(requestId: $requestId) { id requestId } }"

    let requestId: GraphQLID

    var variables: Variables {
        Variables(requestId: requestId)
    }
}

private final class MockGraphQLWebSocketConnector: GraphQLWebSocketConnecting, @unchecked Sendable {
    private let socket: MockGraphQLWebSocketTask
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    init(socket: MockGraphQLWebSocketTask) {
        self.socket = socket
    }

    func graphQLWebSocketTask(with request: URLRequest) -> any GraphQLWebSocketTask {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return socket
    }
}

private final class MockGraphQLWebSocketTask: GraphQLWebSocketTask, @unchecked Sendable {
    private let state: MockGraphQLWebSocketTaskState

    var sentStrings: [String] {
        get async {
            await state.sentStrings
        }
    }

    var didResume: Bool {
        get async {
            await state.didResume
        }
    }

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.state = MockGraphQLWebSocketTaskState(messages: messages)
    }

    func resume() {
        Task {
            await state.resume()
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        await state.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await state.receive()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

private actor MockGraphQLWebSocketTaskState {
    private var messages: [URLSessionWebSocketTask.Message]
    private var storedSentStrings: [String] = []
    private var resumed = false

    var sentStrings: [String] {
        storedSentStrings
    }

    var didResume: Bool {
        resumed
    }

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.messages = messages
    }

    func resume() {
        resumed = true
    }

    func send(_ message: URLSessionWebSocketTask.Message) {
        if case .string(let text) = message {
            storedSentStrings.append(text)
        }
    }

    func receive() throws -> URLSessionWebSocketTask.Message {
        guard !messages.isEmpty else {
            throw GraphQLWebSocketError.unsupportedMessage
        }
        return messages.removeFirst()
    }
}
